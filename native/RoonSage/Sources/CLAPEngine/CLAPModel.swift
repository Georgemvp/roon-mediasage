import Accelerate
import CoreML
import Foundation

/// Native CLAP inference. Wraps the two Core ML packages produced by
/// `native/scripts/convert_clap_to_coreml.py` and turns audio into a 512-dim
/// L2-normalized embedding in CLAP's shared audio/text space, plus mood scores
/// via cosine against precomputed (Core ML) mood-label embeddings.
///
/// Loading is best-effort: `load()` returns nil (and logs) when the models are
/// absent, so the analyzer degrades gracefully to scalar-only features.
public final class CLAPModel: @unchecked Sendable {
    public static let embeddingDim = 512
    public let modelVersion: String

    private let audioModel: MLModel
    private let textModel: MLModel
    private let mel: CLAPMel
    private let moodLabels: [String]
    // [label][512], L2-normalized. Loaded from the baked `clap_mood_embeds.f32`
    // (bare label words), then overwritten by `prepareMoodProbes()` with richer
    // prompt embeddings when the text tower is available.
    private var moodEmbeds: [[Float]]
    private let tokenizer: RobertaBPETokenizer?
    public static let textTokenLength = 64   // must match the converted text model

    // MARK: - Loading

    /// Resolve the directory holding the `.mlpackage` files + resources.
    /// Order: `ROONSAGE_CLAP_DIR` env → the installed location populated by
    /// `scripts/setup_clap_models.sh` (Application Support) → dev path next to
    /// this source file. A model marker (`clap_mel.json`) must be present.
    static func resourceDir() -> URL? {
        let fm = FileManager.default
        func valid(_ u: URL) -> Bool { fm.fileExists(atPath: u.appendingPathComponent("clap_mel.json").path) }

        if let env = ProcessInfo.processInfo.environment["ROONSAGE_CLAP_DIR"], !env.isEmpty {
            let u = URL(fileURLWithPath: env)
            if valid(u) { return u }
        }
        if let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let u = support.appendingPathComponent("RoonSageAnalyzer/CLAP", isDirectory: true)
            if valid(u) { return u }
        }
        let dev = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/CLAP", isDirectory: true)
        return valid(dev) ? dev : nil
    }

    public static func load() -> CLAPModel? {
        guard let dir = resourceDir() else {
            NSLog("[CLAP] no model directory found — embeddings disabled")
            return nil
        }
        sweepStaleTempBundles()
        do {
            let model = try CLAPModel(dir: dir)
            model.prepareProbes()       // build attribute probes once (best-effort)
            model.prepareMoodProbes()   // richer mood prompts over the baked embeds
            return model
        } catch {
            NSLog("[CLAP] failed to load model: \(error) — embeddings disabled")
            return nil
        }
    }

    init(dir: URL) throws {
        let cfg = try MelConfig(dir: dir)
        // -v3: full-track windowed embedding (see `embed(url:)`), AudioMuse-parity.
        // Bumping the suffix makes the LibraryWalker re-embed every older row
        // (embedding-only — scalars kept).
        self.modelVersion = "clap-\(cfg.model.split(separator: "/").last ?? "")-v3"

        let filters = try Self.loadF32(dir.appendingPathComponent("clap_mel_filters.f32"))
        self.mel = CLAPMel(melFilters: filters)

        let audioURL = dir.appendingPathComponent("CLAPAudio.mlpackage")
        let textURL = dir.appendingPathComponent("CLAPText.mlpackage")
        let cfgML = MLModelConfiguration()
        // Opt-out of the ANE/GPU path, off by default.
        //
        // Production leaves this unset and stays on `.all`: the analyzer has run
        // CLAP over 41.699 tracks across 70 sessions without a single crash, and
        // `.all` is measurably faster there. The SAME code in a short-lived test
        // process trips an assertion inside Apple's MPSGraph
        // (`shape.count = 0 != strides.count = 2` → SIGABRT) in 5 of 16 runs;
        // on `.cpuOnly` it was 0 of 24. The assertion is in framework code we
        // cannot fix, so the tests avoid the trigger instead.
        //
        // TRADE-OFF, deliberate: CI therefore no longer exercises the ANE/GPU
        // backend. The embedding maths is backend-independent (the golden-vector
        // assertions are unchanged and still pass), but a regression specific to
        // the accelerated path would not be caught here.
        if ProcessInfo.processInfo.environment["ROONSAGE_CLAP_CPU_ONLY"] == "1" {
            cfgML.computeUnits = .cpuOnly
        }
        let audioCompiled = try Self.compiledModel(name: "CLAPAudio", source: audioURL, version: self.modelVersion)
        let textCompiled = try Self.compiledModel(name: "CLAPText", source: textURL, version: self.modelVersion)
        self.audioModel = try MLModel(contentsOf: audioCompiled, configuration: cfgML)
        self.textModel = try MLModel(contentsOf: textCompiled, configuration: cfgML)

        self.tokenizer = RobertaBPETokenizer(dir: dir)   // best-effort (text search)
        self.moodLabels = cfg.moodLabels
        let moodFlat = try Self.loadF32(dir.appendingPathComponent("clap_mood_embeds.f32"))
        let d = Self.embeddingDim
        precondition(moodFlat.count == cfg.moodLabels.count * d, "mood embeds size mismatch")
        self.moodEmbeds = (0..<cfg.moodLabels.count).map { Array(moodFlat[$0 * d..<($0 + 1) * d]) }
    }

    // MARK: - Compiled-model cache

    /// Compile a `.mlpackage` once into a stable, version-keyed cache directory
    /// and reuse it thereafter.
    ///
    /// `MLModel.compileModel(at:)` writes a fresh `<name>_<UUID>.mlmodelc` into
    /// `$TMPDIR` and hands ownership of that URL to the caller. Compiling inline
    /// and dropping the URL leaked ~750 MB of orphaned bundles into temp on every
    /// process launch. We compile-if-missing into Application Support instead,
    /// which also avoids recompiling the ~478 MB RoBERTa text tower each run.
    private static func compiledModel(name: String, source: URL, version: String) throws -> URL {
        let fm = FileManager.default
        let cacheRoot = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("RoonSageAnalyzer/CLAP/compiled/\(version)", isDirectory: true)
        let dest = cacheRoot?.appendingPathComponent("\(name).mlmodelc", isDirectory: true)

        if let dest, fm.fileExists(atPath: dest.path) {
            return dest   // already compiled for this model version — reuse
        }

        // Apple's API gives us no choice but to compile into $TMPDIR; adopt the
        // result into the cache so it does not accumulate there.
        let compiled = try MLModel.compileModel(at: source)
        guard let cacheRoot, let dest else { return compiled }   // no cache location; rare
        do {
            try fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) { try? fm.removeItem(at: dest) }
            try fm.moveItem(at: compiled, to: dest)
            return dest
        } catch {
            NSLog("[CLAP] could not cache compiled \(name): \(error) — using temp copy")
            return compiled
        }
    }

    /// Best-effort removal of orphaned `CLAP{Audio,Text}_<UUID>.mlmodelc` bundles
    /// that older builds leaked into `$TMPDIR`. Safe: these are pure compile
    /// artifacts, regenerated on demand. A 10-minute age floor avoids racing a
    /// compile that another process may have in flight.
    static func sweepStaleTempBundles() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: fm.temporaryDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-600)
        for u in items where u.pathExtension == "mlmodelc" {
            let n = u.lastPathComponent
            guard n.hasPrefix("CLAPAudio_") || n.hasPrefix("CLAPText_") else { continue }
            let mod = (try? u.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let mod, mod > cutoff { continue }   // recent — may be an active compile
            try? fm.removeItem(at: u)
        }
    }

    // MARK: - Audio embedding

    /// 512-dim L2-normalized embedding for mono samples at 48 kHz.
    ///
    /// The whole body runs inside an `autoreleasepool`: `MLMultiArray`,
    /// `MLDictionaryFeatureProvider`, the prediction output and the MPSGraph/Metal
    /// command-buffer temporaries CoreML spawns are all autoreleased ObjC objects.
    /// This method is called once PER WINDOW (up to ~360 times for a 30-min track)
    /// on a Swift-concurrency worker thread that has NO run loop — so without an
    /// explicit pool those temporaries accumulate for the whole track (and across
    /// the whole walk), which is the analyzer's RAM-spike source. Draining per call
    /// keeps peak footprint at one window's worth.
    public func embed(samples: [Float]) throws -> [Float] {
        try autoreleasepool {
            let logMel = mel.logMel(samples)   // [frames * nMels], row-major
            let arr = try MLMultiArray(
                shape: [1, 1, NSNumber(value: CLAPMel.frames), NSNumber(value: CLAPMel.nMels)],
                dataType: .float32)
            logMel.withUnsafeBufferPointer { src in
                let dst = arr.dataPointer.assumingMemoryBound(to: Float.self)
                dst.update(from: src.baseAddress!, count: src.count)
            }
            let provider = try MLDictionaryFeatureProvider(
                dictionary: ["input_features": MLFeatureValue(multiArray: arr)])
            let out = try audioModel.prediction(from: provider)
            guard let emb = out.featureValue(for: "embedding")?.multiArrayValue else {
                throw CLAPError.missingOutput
            }
            return Self.l2(Self.toFloats(emb))
        }
    }

    /// Full-track windowing (AudioMuse-parity): 10 s segments every 5 s (2×
    /// overlap) across the WHOLE track, plus a flush-to-end tail segment. Each
    /// window is L2-normalized and averaged into one centroid (re-normalized),
    /// so intros/outros/bridges all contribute — a long build-up or a quiet
    /// opening no longer misrepresents the song.
    static let windowSamples = CLAPMel.clipSamples          // 10 s @ 48 kHz
    static let windowHopSamples = CLAPMel.clipSamples / 2   // 5 s hop
    /// Coverage cap: covers virtually every real track in full. Memory no longer
    /// scales with track length — `embed(url:)` streams the windows (see
    /// `AudioDecoder.decodeWindows`), so peak footprint is one window regardless of
    /// this value; the cap now only bounds CPU (windows embedded) on pathological
    /// hour-long files.
    static let maxEmbedSeconds: Double = 1800

    /// Stream the whole track's windows in bounded memory and embed their mean
    /// direction. Falls back to three seeked 10 s windows (25/50/75%), then to a
    /// single window from the start — a failed streaming decode never blocks the
    /// embed entirely.
    public func embed(url: URL) throws -> [Float] {
        if let e = try? embedStreamed(url: url) { return e }
        return try embedSampledWindows(url: url)
    }

    /// Streaming full-track embedding: decode + window without ever holding the
    /// whole 48 kHz PCM (`AudioDecoder.decodeWindows`). Emits the SAME window set
    /// as `embedWindowed`, so the mean-direction result is byte-identical to the
    /// old decode-all path — only peak memory differs. Throws when no window embeds
    /// (→ caller falls back to `embedSampledWindows`).
    func embedStreamed(url: URL) throws -> [Float] {
        var sum = [Float](repeating: 0, count: Self.embeddingDim)
        var n = 0
        try AudioDecoder.decodeWindows(
            url: url, targetSampleRate: Double(CLAPMel.sampleRate),
            windowSamples: Self.windowSamples, hopSamples: Self.windowHopSamples,
            maxSeconds: Self.maxEmbedSeconds
        ) { window in
            guard let e = try? self.embed(samples: window), e.count == Self.embeddingDim else { return }
            vDSP_vadd(sum, 1, e, 1, &sum, 1, vDSP_Length(Self.embeddingDim))
            n += 1
        }
        guard n > 0 else { throw CLAPError.missingOutput }
        return Self.l2(sum)   // mean direction of the windows, unit-normalized
    }

    /// Mean-direction embedding of 10 s windows (5 s hop + tail) over `samples`.
    /// n=25 s: starts 0/5/10/15 s, tail 15 s == last -> 4 windows;
    /// n=26 s: starts 0/5/10/15 s + tail 16 s -> 5; n<=10 s: single (padded) window.
    func embedWindowed(samples: [Float]) throws -> [Float] {
        let w = Self.windowSamples, hop = Self.windowHopSamples
        guard samples.count > w else { return try embed(samples: samples) }
        var starts = Array(stride(from: 0, through: samples.count - w, by: hop))
        let tail = samples.count - w
        if starts.last != tail { starts.append(tail) }   // flush-to-end segment
        var sum = [Float](repeating: 0, count: Self.embeddingDim)
        var n = 0
        for s in starts {
            guard let e = try? embed(samples: Array(samples[s..<s + w])),
                  e.count == Self.embeddingDim else { continue }
            vDSP_vadd(sum, 1, e, 1, &sum, 1, vDSP_Length(Self.embeddingDim))
            n += 1
        }
        guard n > 0 else { throw CLAPError.missingOutput }
        return Self.l2(sum)   // mean direction of the windows, unit-normalized
    }

    /// Legacy fallback (pre-v3 behavior): three seeked 10 s windows at
    /// 25/50/75% of the track, mean direction; a single window from the start
    /// when every windowed decode/embed fails.
    private func embedSampledWindows(url: URL) throws -> [Float] {
        let secs = Double(CLAPMel.clipSamples) / Double(CLAPMel.sampleRate)
        var sum = [Float](repeating: 0, count: Self.embeddingDim)
        var n = 0
        for f in [0.25, 0.5, 0.75] {
            guard let audio = try? AudioDecoder.decode(
                url: url, targetSampleRate: Double(CLAPMel.sampleRate),
                maxSeconds: secs, startFraction: f),
                let e = try? embed(samples: audio.samples), e.count == Self.embeddingDim
            else { continue }
            vDSP_vadd(sum, 1, e, 1, &sum, 1, vDSP_Length(Self.embeddingDim))
            n += 1
        }
        guard n > 0 else {
            let audio = try AudioDecoder.decode(
                url: url, targetSampleRate: Double(CLAPMel.sampleRate),
                maxSeconds: secs, startFraction: 0)
            return try embed(samples: audio.samples)
        }
        return Self.l2(sum)
    }

    // MARK: - Moods

    /// Cosine similarity of an audio embedding to each mood label.
    public func moods(forEmbedding emb: [Float]) -> [String: Float] {
        let e = Self.l2(emb)
        var result = [String: Float](minimumCapacity: moodLabels.count)
        for (i, label) in moodLabels.enumerated() {
            result[label] = Self.dot(e, moodEmbeds[i])
        }
        return result
    }

    /// Richer text prompts per mood label, replacing the bare label words the
    /// baked `clap_mood_embeds.f32` used. The single words collapsed concepts in
    /// CLAP's shared space (e.g. "happy" barely separated from "danceable"/
    /// "party", so raw argmax under-picked it); phrases separate them better.
    /// Keyed by label; `prepareMoodProbes()` builds embeds in `moodLabels` order.
    /// Heuristic — validate the resulting mood distribution after a re-tag.
    static let moodPrompts: [String: [String]] = [
        "danceable":  ["danceable groovy music with a strong steady beat", "an upbeat club track you can dance to"],
        "aggressive": ["aggressive intense heavy music", "an angry hard-hitting powerful song"],
        "happy":      ["happy joyful cheerful feel-good music", "a bright upbeat positive song"],
        "party":      ["energetic celebratory party music", "a festive crowd-pleasing anthem"],
        "relaxed":    ["calm relaxed mellow gentle music", "a soft soothing laid-back song"],
        "sad":        ["sad melancholic emotional music", "a sorrowful heartbreaking song"],
    ]

    /// Recompute `moodEmbeds` from `moodPrompts` via the text tower so mood
    /// scoring uses richer prompts than the baked single-word embeds. No-op
    /// (keeps the baked embeds) when the text tower is unavailable; per label it
    /// falls back to the baked embed if that prompt fails to embed. Changing a
    /// prompt shifts stored moods until the library is re-tagged. Call once after
    /// load, alongside `prepareProbes()`.
    func prepareMoodProbes() {
        guard canEmbedText else { return }
        var rebuilt = moodEmbeds
        for (i, label) in moodLabels.enumerated() {
            guard let phrases = Self.moodPrompts[label],
                  let v = meanUnitEmbedding(phrases) else { continue }
            rebuilt[i] = v
        }
        moodEmbeds = rebuilt
    }

    // MARK: - Attribute axes (zero-shot text probes)

    /// One interpretable 0…1 axis defined by contrasting text prompts, scored from
    /// the audio embedding via CLAP's shared space — "Spotify-style" meta for free,
    /// no extra model. Probe phrasing + the logistic scale are heuristic and worth
    /// tuning against real audio.
    struct AttributeAxis { let name: String; let positive: [String]; let negative: [String] }
    static let attributeAxes: [AttributeAxis] = [
        AttributeAxis(name: "valence",
            positive: ["happy joyful uplifting positive music", "cheerful bright feel-good song"],
            negative: ["sad melancholic depressing music", "dark gloomy somber song"]),
        AttributeAxis(name: "danceability",
            positive: ["danceable groovy rhythmic music with a strong steady beat", "club dance track you can dance to"],
            negative: ["free-form ambient music with no beat", "slow arrhythmic music you cannot dance to"]),
        AttributeAxis(name: "acousticness",
            positive: ["acoustic unplugged music on organic real instruments", "natural acoustic recording with guitar piano strings"],
            negative: ["electronic synthetic produced music", "heavily synthesized electronic track full of synths"]),
        AttributeAxis(name: "instrumentalness",
            positive: ["instrumental music with no vocals", "purely instrumental track without any singing"],
            negative: ["song with prominent lead vocals and singing", "track with a singer and lyrics"]),
        // Perceptual energy/arousal from the CLAP embedding — a semantic
        // intensity read, NOT the waveform's linear RMS (which is dominated by
        // mastering and mis-orders busy-but-quiet vs loud-but-sparse tracks). The
        // radios prefer this over `energy` for gates/titles/sequencing.
        AttributeAxis(name: "arousal",
            positive: ["high-energy intense driving powerful music", "energetic aggressive banging peak-time track"],
            negative: ["calm gentle mellow soft music", "slow relaxed sparse low-energy ambient piece"]),
    ]

    /// Precomputed per-axis mean positive/negative unit vectors. Empty when the
    /// text tokenizer is unavailable. Set once by `prepareProbes()` (single-thread,
    /// right after load); `attributes(forEmbedding:)` then reads them concurrently.
    private var attrProbes: [(name: String, pos: [Float], neg: [Float])] = []

    /// L2-normalized mean of the text embeddings of `phrases` (nil if none
    /// embed). Shared by the attribute (`prepareProbes`) and mood
    /// (`prepareMoodProbes`) probe builders.
    private func meanUnitEmbedding(_ phrases: [String]) -> [Float]? {
        var acc = [Float](repeating: 0, count: Self.embeddingDim); var n = 0
        for p in phrases {
            guard let e = try? textEmbedding(p), e.count == Self.embeddingDim else { continue }
            vDSP_vadd(acc, 1, e, 1, &acc, 1, vDSP_Length(Self.embeddingDim)); n += 1
        }
        return n > 0 ? Self.l2(acc) : nil
    }

    /// Build the attribute probe vectors via the text model. Call once after load.
    func prepareProbes() {
        guard canEmbedText else { return }
        var probes: [(name: String, pos: [Float], neg: [Float])] = []
        for axis in Self.attributeAxes {
            guard let pos = meanUnitEmbedding(axis.positive),
                  let neg = meanUnitEmbedding(axis.negative) else { continue }
            probes.append((axis.name, pos, neg))
        }
        attrProbes = probes
    }

    /// 0…1 attribute scores for an audio embedding (empty when probes unavailable).
    /// Each axis maps the positive-vs-negative cosine contrast through a logistic.
    public func attributes(forEmbedding emb: [Float]) -> [String: Float] {
        guard !attrProbes.isEmpty else { return [:] }
        let e = Self.l2(emb)
        var result = [String: Float](minimumCapacity: attrProbes.count)
        for p in attrProbes {
            let contrast = Self.dot(e, p.pos) - Self.dot(e, p.neg)
            result[p.name] = 1 / (1 + expf(-8 * contrast))
        }
        return result
    }

    // MARK: - Text

    public var canEmbedText: Bool { tokenizer != nil }

    /// 512-dim L2-normalized embedding of free text (CLAP shared space), for
    /// text→audio search. Throws when the tokenizer isn't available.
    public func textEmbedding(_ text: String) throws -> [Float] {
        guard let tokenizer else { throw CLAPError.noTokenizer }
        let (ids, mask) = tokenizer.encode(text, maxLength: Self.textTokenLength)
        return try textEmbedding(tokenIds: ids, attentionMask: mask)
    }

    /// 512-dim L2-normalized text embedding from pre-tokenized ids + mask.
    public func textEmbedding(tokenIds: [Int32], attentionMask: [Int32]) throws -> [Float] {
        try autoreleasepool {   // drain CoreML temporaries per call (see embed(samples:))
            let len = tokenIds.count
            let ids = try MLMultiArray(shape: [1, NSNumber(value: len)], dataType: .int32)
            let mask = try MLMultiArray(shape: [1, NSNumber(value: len)], dataType: .int32)
            for i in 0..<len {
                ids[i] = NSNumber(value: tokenIds[i])
                mask[i] = NSNumber(value: attentionMask[i])
            }
            let provider = try MLDictionaryFeatureProvider(dictionary: [
                "input_ids": MLFeatureValue(multiArray: ids),
                "attention_mask": MLFeatureValue(multiArray: mask),
            ])
            let out = try textModel.prediction(from: provider)
            guard let emb = out.featureValue(for: "embedding")?.multiArrayValue else {
                throw CLAPError.missingOutput
            }
            return Self.l2(Self.toFloats(emb))
        }
    }

    // MARK: - Helpers

    enum CLAPError: Error { case missingOutput, noTokenizer }

    private static func loadF32(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        return data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
    }

    private static func toFloats(_ m: MLMultiArray) -> [Float] {
        let n = m.count
        var out = [Float](repeating: 0, count: n)
        if m.dataType == .float32 {
            let p = m.dataPointer.assumingMemoryBound(to: Float.self)
            out.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: p, count: n) }
        } else {
            for i in 0..<n { out[i] = m[i].floatValue }
        }
        return out
    }

    static func l2(_ v: [Float]) -> [Float] {
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        norm = norm.squareRoot()
        guard norm > 1e-9 else { return v }
        var out = [Float](repeating: 0, count: v.count)
        var inv = 1.0 / norm
        vDSP_vsmul(v, 1, &inv, &out, 1, vDSP_Length(v.count))
        return out
    }

    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        var r: Float = 0
        vDSP_dotpr(a, 1, b, 1, &r, vDSP_Length(min(a.count, b.count)))
        return r
    }
}

/// Minimal decoder for `clap_mel.json` — only the fields Swift needs.
private struct MelConfig {
    let model: String
    let moodLabels: [String]

    init(dir: URL) throws {
        let data = try Data(contentsOf: dir.appendingPathComponent("clap_mel.json"))
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        self.model = obj["model"] as? String ?? "laion/clap"
        self.moodLabels = obj["mood_labels"] as? [String] ?? []
    }
}
