import AudioAnalysis
import Foundation

// MARK: - Discovery sonic-fit (CLAP long-tail, fase 1)
//
// Candidates we don't own were never analyzed, so they carry no CLAP embedding —
// the discovery score can only lean on collaborative/metadata signals. This
// closes that gap for the top of a batch: fetch a 30 s Deezer preview, CLAP-embed
// it, and cosine it against the user's (L2-normalized) taste centroid, then fold
// that sonic fit into the score as a small bounded nudge. Best-effort: a missing
// preview, a failed decode, or no loaded CLAP model simply leaves the score
// untouched (the batch degrades to its pre-sonic ranking). The `nudge` mapping is
// pure and unit-tested; `cosineToTaste` is network/IO glue like every producer.

public enum DiscoverySonicFit {

    /// Max score nudge from sonic fit — bounded, like the album/popularity
    /// modifiers, so a miscalibrated cosine can only re-rank within the ballpark,
    /// never dominate the collaborative/metadata score.
    public static let sonicFitWeight = 0.12

    /// Cosine at which sonic fit is neutral (no nudge). Both vectors are L2-
    /// normalized, so cosine ∈ [-1, 1]; a track vs a taste centroid clusters in
    /// roughly [0, 0.6], so 0.3 is a sensible middle.
    public static let neutralCosine = 0.3

    /// How far above/below `neutral` a cosine must sit to reach the full ±weight.
    static let cosineScale = 0.3

    /// Map a CLAP cosine to a bounded ± nudge: above `neutral` lifts, below trims,
    /// clamped to ±`weight`. Linear between, saturating at ±1·weight.
    public static func nudge(cosine: Double, neutral: Double = neutralCosine, weight: Double = sonicFitWeight) -> Double {
        let t = max(-1, min(1, (cosine - neutral) / cosineScale))
        return weight * t
    }

}

/// The CLAP side of sonic fit, behind a protocol so RoonSageCore never links the
/// model.
///
/// RoonSageCore is what every client app (macOS, iOS) depends on. Referring to
/// `CLAPModel` here used to drag the 746 MB CLAPEngine resource bundle into
/// RoonSage.app on both platforms — for a bounded ±0.12 re-rank that only ever
/// runs on the server build. So the two CLAP capabilities the discovery run
/// needs are declared here and implemented by whoever actually owns a model
/// (`ClapSonicFit`, in the analyser app). No registrant → both call sites see
/// nil and the batch keeps its pre-sonic ranking, which is the same degradation
/// path a missing model already took.
public protocol SonicFitScoring: Sendable {

    /// CLAP text embedding for a free-text vibe, or nil when this provider has no
    /// text tokenizer (the old `canEmbedText` guard, folded into the return).
    func textEmbedding(_ text: String) async -> [Float]?

    /// Download `previewURL`, CLAP-embed it, and cosine against the taste
    /// centroid. nil on any download/decode/embed failure — the caller then
    /// leaves the score untouched.
    func cosineToTaste(previewURL: URL, centroid: [Float]) async -> Double?
}

/// Process-wide registry for the sonic-fit provider.
///
/// Replaces the old `SonicFitClap` lazy model handle: the laziness now lives in
/// the registrant (which owns the expensive `CLAPModel.load()`), and this only
/// answers "is there one?". Unregistered on every client build by design.
public actor SonicFit {
    public static let shared = SonicFit()

    private var registered: SonicFitScoring?

    /// Provider, or nil when nothing registered one (every client build).
    public var provider: SonicFitScoring? { registered }

    /// Called once by the server build during start-up.
    public func register(_ provider: SonicFitScoring) { registered = provider }
}
