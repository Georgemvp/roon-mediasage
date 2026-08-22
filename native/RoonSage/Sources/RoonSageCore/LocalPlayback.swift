import Foundation
import Observation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Plays library audio **on this device** — the iPhone (or Mac) as a listening
/// endpoint, independent of Roon's zones. Roon's own output (RAAT) is a licensed
/// closed SDK a third party can't join, so instead of registering a Roon zone we
/// stream the track's on-disk file from the analyser server's `/audio` endpoint
/// and decode it locally with AVFoundation.
///
/// This is a self-contained engine: it owns an `AVPlayer`, a small queue, the
/// audio session (iOS), and publishes observable state the UI binds to. It does
/// NOT touch `MPNowPlayingInfoCenter` — the iOS app's `NowPlayingCenter` reads
/// this engine and owns the system now-playing surface, so there's a single
/// writer. `onStateChange` lets that layer refresh on every transition.
@MainActor
@Observable
public final class LocalPlaybackController {
    public static let shared = LocalPlaybackController()

    /// A queued track. `id` is the library match key — the `/audio` lookup key.
    /// `streamURLOverride`, when set, is played directly (used for Qobuz: a
    /// signed CDN URL the phone fetches itself, bypassing the `/audio` server).
    public struct Track: Identifiable, Sendable, Equatable {
        public let id: String
        public let title: String
        public let artist: String
        public let album: String
        public let imageKey: String?
        public let durationSec: Double?
        public let streamURLOverride: URL?
        /// K-weighted LUFS of this track / mean of its album (analyzer, F3) —
        /// drive the loudness-normalization gain; nil when not measured.
        public let lufs: Double?
        public let albumLufs: Double?
        public init(id: String, title: String, artist: String, album: String,
                    imageKey: String?, durationSec: Double?, streamURLOverride: URL? = nil,
                    lufs: Double? = nil, albumLufs: Double? = nil) {
            self.id = id; self.title = title; self.artist = artist
            self.album = album; self.imageKey = imageKey; self.durationSec = durationSec
            self.streamURLOverride = streamURLOverride
            self.lufs = lufs; self.albumLufs = albumLufs
        }
    }

    public private(set) var queue: [Track] = []
    public private(set) var index: Int = 0
    public private(set) var isPlaying: Bool = false
    /// True while a local session is loaded — the UI uses this to know that
    /// "Deze iPhone" owns now-playing/transport (vs. a Roon zone).
    public private(set) var isEngaged: Bool = false
    public private(set) var positionSec: Double = 0
    /// User-facing error from the last action (e.g. a track that wouldn't load).
    public var lastError: String?

    // MARK: Shuffle / repeat / volume — parity with the Roon zone hero, so the
    // merged Now Playing screen offers the same controls whether you're on a
    // zone or this device.

    /// Shuffle upcoming tracks (keeps the current one playing). Restoring the
    /// original order needs the untouched list, so `baseQueue` is kept alongside.
    public private(set) var shuffle: Bool = false
    /// "disabled" | "loop" (whole queue) | "loop_one" (repeat current) — the same
    /// vocabulary as Roon's loop mode, cycled via `NowPlayingHeroOptions.nextLoop`.
    public private(set) var loopMode: String = "disabled"
    /// User volume level 0…1, applied as a multiplier ON TOP of the loudness
    /// normalization gain (so the two never fight — see `reapplyVolume`).
    public private(set) var volume: Double = 1.0
    public private(set) var isMuted: Bool = false
    /// The queue in its ORIGINAL order, so turning shuffle off restores it.
    @ObservationIgnored private var baseQueue: [Track] = []
    /// Loudness-normalization gain for the current item; `player.volume` is this
    /// times the user volume (see `reapplyVolume`).
    @ObservationIgnored private var loudnessGain: Float = 1.0

    public var current: Track? { queue.indices.contains(index) ? queue[index] : nil }

    /// Duration of the current track — the player's value once known, else the
    /// metadata hint.
    ///
    /// STORED and observable on purpose. It used to be computed straight from
    /// `player.currentItem.duration`, which SwiftUI cannot observe: a streamed
    /// asset reports its length a moment AFTER playback starts, and nothing
    /// re-rendered when it did. Together with a scrubber that skipped reading
    /// `positionSec` while the duration was still 0, that froze the whole
    /// progress row at 0:00 — until an unrelated observable (pausing) forced a
    /// redraw and the real time appeared.
    public private(set) var durationSec: Double = 0

    /// Pull the current item's length, falling back to the metadata hint. Called
    /// on every position tick, so a duration that resolves late still lands.
    private func refreshDuration() {
        var next = current?.durationSec ?? 0
        #if canImport(AVFoundation)
        if let item = player.currentItem {
            let d = item.duration.seconds
            if d.isFinite, d > 0 { next = d }
        }
        #endif
        if durationSec != next { durationSec = next }
    }

    /// Set by the iOS app so it can refresh `MPNowPlayingInfoCenter` and the
    /// home-screen widget whenever the engine's state changes. Kept as a closure
    /// so this core type never imports MediaPlayer. `@MainActor` so the handler
    /// can touch main-actor UI/system state directly.
    public var onStateChange: (@MainActor () -> Void)?

    /// Fired once per *track change* (not on every state tick), so a listener can
    /// do the things a new song warrants exactly once.
    ///
    /// Deliberately separate from `onStateChange`: that one is owned by the iOS
    /// app for `MPNowPlayingInfoCenter` and fires ~2 Hz off the time observer.
    /// `RoonClient` uses this hook to scrobble and log a listen — which zone
    /// playback has always done from the zone-frame handler, and on-device
    /// playback did not do at all.
    public var onTrackChange: (@MainActor (Track) -> Void)?

    #if canImport(AVFoundation)
    /// `AVQueuePlayer`, not `AVPlayer`, so the next track can be handed to the
    /// render pipeline *before* the current one ends — that's what removes the
    /// gap. It holds at most two items (playing + follower); `queue`/`index`
    /// above stay the single source of truth for the whole play order.
    @ObservationIgnored private let player = AVQueuePlayer()
    /// The items currently handed to the player, paired with the queue position
    /// each one came from. Head = playing, optional tail = pre-enqueued
    /// follower. This mapping is how an automatic handover is detected: when
    /// `currentItem` changes to the tail, the player advanced by itself.
    /// `hasMix` records HOW this item's loudness gain is applied. A hard load
    /// keeps using `player.volume` (the user just pressed play; a settle there is
    /// unremarkable). The pre-enqueued follower instead carries its gain in its
    /// own `AVAudioMix`, attached seconds in advance — because at a gapless
    /// boundary the player-level route lands a KVO hop late, which is exactly the
    /// level step other clients report as a click. One mechanism per item, chosen
    /// when the item is made; they never both apply.
    @ObservationIgnored private var scheduled: [(index: Int, item: AVPlayerItem, hasMix: Bool)] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var currentItemObserver: NSKeyValueObservation?
    /// True while `load` is tearing the player down and refilling it.
    ///
    /// `removeAllItems()` drives `currentItem` to nil SYNCHRONOUSLY, which fires
    /// the observer below, which reads nil as "the queue ran dry" and calls
    /// `stop()` — emptying `queue` out from under the rest of `load`, which then
    /// subscripts it and crashes. Fresh playback never hit it (an empty player's
    /// `currentItem` doesn't change), so it only bit when switching tracks WHILE
    /// something was already playing: jumping in the queue, Journey, Play this mix.
    @ObservationIgnored private var isRebuilding = false
    /// Watches the current item's `status` so a server-side failure surfaces as a
    /// visible error instead of a silent "engaged but no sound".
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?
    #endif
    /// Ramp length for pause/resume, and the longer one the sleep timer uses.
    static let transportFade: Double = 0.12
    public static let sleepFade: Double = 2.0
    #if canImport(AVFoundation)
    @ObservationIgnored private var fadeTask: Task<Void, Never>?
    #endif
    @ObservationIgnored private var streamBase: String = ""
    @ObservationIgnored private var token: String?

    private init() {
        #if canImport(AVFoundation)
        // The player advances on its own now, so end-of-track is observed as a
        // change of `currentItem` rather than a didPlayToEndTime notification.
        // KVO fires on the main queue here (the main actor's executor), so assume
        // isolation instead of hopping through a Task — that keeps the handover
        // synchronous and avoids sending the non-Sendable item across actors.
        currentItemObserver = player.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
            let item = player.currentItem
            MainActor.assumeIsolated { self?.handleCurrentItemChanged(to: item) }
        }
        // ~2 Hz position updates drive the scrubber + lock-screen elapsed time.
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.positionSec = time.seconds.isFinite ? max(0, time.seconds) : 0
                self.refreshDuration()
                self.onStateChange?()
            }
        }
        #endif
    }

    // MARK: - Public transport

    /// Load a queue and start playing on this device. `streamBase` is the
    /// analyser server base (e.g. `http://host:5766`); `token` is the shared
    /// secret (sent as `X-RoonSage-Token`), nil if unpaired.
    public func play(_ tracks: [Track], streamBase: String, token: String?, startAt: Int = 0) {
        guard !tracks.isEmpty else { return }
        var base = streamBase.trimmingCharacters(in: .whitespaces)
        if base.hasSuffix("/") { base.removeLast() }
        self.streamBase = base
        self.token = token
        baseQueue = tracks
        queue = tracks
        isEngaged = true
        lastError = nil
        activateSession()
        let start = min(max(0, startAt), tracks.count - 1)
        if shuffle {
            applyShuffleOrder(startingAt: start)
            load(index: 0, autoPlay: true)
        } else {
            load(index: start, autoPlay: true)
        }
    }

    // MARK: - Shuffle / repeat / volume

    /// Toggle shuffle without interrupting the current track: rebuild the queue
    /// array around the playing item (shuffled upcoming, or the original order).
    public func setShuffle(_ on: Bool) {
        guard shuffle != on else { return }
        shuffle = on
        guard isEngaged else { onStateChange?(); return }
        let cur = current
        if on {
            let curIdx = cur.flatMap { c in baseQueue.firstIndex(where: { $0.id == c.id }) } ?? index
            applyShuffleOrder(startingAt: curIdx)
        } else {
            queue = baseQueue
            index = cur.flatMap { c in baseQueue.firstIndex(where: { $0.id == c.id }) } ?? 0
        }
        invalidateFollower()
        onStateChange?()
    }

    /// Set the repeat mode ("disabled" | "loop" | "loop_one").
    public func setLoop(_ mode: String) {
        loopMode = mode
        // The mode decides what plays next, and that track may already be handed
        // to the player — re-pick it. (Switching to "repeat one" mid-track makes
        // the current track its own follower.)
        invalidateFollower()
        onStateChange?()
    }

    /// Set the user volume (0…1). A non-zero level clears mute.
    public func setVolume(_ value: Double) {
        volume = min(max(value, 0), 1)
        if volume > 0 { isMuted = false }
        reapplyVolume()
        onStateChange?()
    }

    public func toggleMute() {
        isMuted.toggle()
        reapplyVolume()
        onStateChange?()
    }

    /// Rebuild `queue` with the chosen base-queue track first and the rest
    /// shuffled after it; leaves `index` at 0 (the current item), so no reload.
    private func applyShuffleOrder(startingAt i: Int) {
        guard !baseQueue.isEmpty else { return }
        var rest = baseQueue
        let first = baseQueue.indices.contains(i) ? rest.remove(at: i) : rest.removeFirst()
        queue = [first] + rest.shuffled()
        index = 0
    }

    private func reapplyVolume() {
        #if canImport(AVFoundation)
        player.volume = targetVolume
        #endif
    }

    #if canImport(AVFoundation)
    /// The level the player should sit at: loudness gain × user volume × mute.
    private var targetVolume: Float { loudnessGain * Float(isMuted ? 0 : volume) }

    /// Ramp `player.volume` to `to` over `duration`, then run `then`.
    ///
    /// A hard cut at pause or stop is audible as a click — the waveform is
    /// chopped mid-cycle. ~120 ms is enough to make it a fade without feeling
    /// sluggish; the sleep timer gets a longer one, since being eased out is the
    /// whole point of falling asleep to music.
    ///
    /// Stepped with a timer rather than an `AVAudioMix`: this ramps the PLAYER,
    /// which is exactly what pause/stop/sleep want, and needs no per-item asset
    /// loading. (The per-item mix is a separate job — it fixes the loudness step
    /// at a gapless track boundary, which this cannot reach.)
    private func fade(to target: Float, over duration: Double, then: (@MainActor () -> Void)? = nil) {
        fadeTask?.cancel()
        let from = player.volume
        guard duration > 0, abs(from - target) > 0.001 else {
            player.volume = target; then?(); return
        }
        let steps = max(1, Int(duration / 0.02))
        fadeTask = Task { @MainActor [weak self] in
            for step in 1...steps {
                if Task.isCancelled { return }
                try? await Task.sleep(nanoseconds: 20_000_000)
                guard let self, !Task.isCancelled else { return }
                self.player.volume = from + (target - from) * Float(step) / Float(steps)
            }
            guard let self, !Task.isCancelled else { return }
            self.player.volume = target
            then?()
        }
    }
    #endif

    public func togglePlayPause() {
        #if canImport(AVFoundation)
        guard isEngaged else { return }
        if isPlaying {
            // Fade out, THEN pause — pausing first would cut the ramp off.
            isPlaying = false
            fade(to: 0, over: Self.transportFade) { [weak self] in self?.player.pause() }
        } else {
            // Start silent and come up, so resuming doesn't thump.
            player.volume = 0
            player.play()
            isPlaying = true
            fade(to: targetVolume, over: Self.transportFade)
        }
        onStateChange?()
        #endif
    }

    /// User-pressed Next: always steps forward, even under "repeat one" (where
    /// the automatic follower is the same track again). "loop" wraps at the end;
    /// otherwise the session stops.
    /// Sleep timer: a long ramp instead of the transport's short one — being
    /// eased out is the whole point of falling asleep to music.
    public func fadeOutAndPause(over duration: Double) {
        #if canImport(AVFoundation)
        guard isEngaged, isPlaying else { return }
        isPlaying = false
        fade(to: 0, over: duration) { [weak self] in self?.player.pause() }
        onStateChange?()
        #endif
    }

    public func next() {
        guard isEngaged else { return }
        let target: Int?
        if index + 1 < queue.count { target = index + 1 }
        else if loopMode == "loop" { target = 0 }
        else { target = nil }
        guard let target else { stop(); return }
        #if canImport(AVFoundation)
        // When the follower the player already holds IS the track we want, skip
        // to it instead of rebuilding: no re-fetch, no reload, instant.
        if scheduled.count > 1, scheduled[1].index == target {
            player.advanceToNextItem()
            if !isPlaying { player.play(); isPlaying = true }
            return
        }
        #endif
        load(index: target, autoPlay: true)
    }

    public func previous() {
        guard isEngaged else { return }
        // Standard behaviour: restart the track if we're past the intro,
        // otherwise step back.
        if positionSec > 3 || index == 0 { seek(toSeconds: 0) }
        else { load(index: index - 1, autoPlay: true) }
    }

    public func seek(toSeconds seconds: Double) {
        #if canImport(AVFoundation)
        guard isEngaged else { return }
        let t = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        player.seek(to: t)
        positionSec = max(0, seconds)
        onStateChange?()
        #endif
    }

    public func seek(toFraction fraction: Double) {
        let d = durationSec
        guard d > 0 else { return }
        seek(toSeconds: max(0, min(1, fraction)) * d)
    }

    /// Tear down the session and clear state — local playback fully stops.
    public func stop() {
        // Cleared FIRST: emptying the player drives `currentItem` to nil, and the
        // observer treats that as "queue ran dry" and calls back into stop().
        // The flag makes that re-entry a no-op.
        isPlaying = false
        isEngaged = false
        #if canImport(AVFoundation)
        fadeTask?.cancel()
        statusObserver?.invalidate()
        statusObserver = nil
        player.pause()
        player.removeAllItems()
        scheduled = []
        #endif
        queue = []
        baseQueue = []
        index = 0
        positionSec = 0
        deactivateSession()
        onStateChange?()
    }

    // MARK: - Queue editing
    //
    // Roon's extension API offers no reorder/remove, so these verbs exist only
    // for the local engine — on this device the queue is a plain array we own.
    // The index bookkeeping lives in `LocalQueue` (pure, unit-tested); this layer
    // only decides when a mutation forces the player to reload.

    /// Add tracks to the queue without interrupting what's playing: straight
    /// after the current track (`next: true`) or at the end. Starting from an
    /// idle engine is the same thing as "play these" — so it delegates.
    public func enqueue(_ tracks: [Track], streamBase: String, token: String?, next: Bool) {
        guard !tracks.isEmpty else { return }
        guard isEngaged, !queue.isEmpty else {
            play(tracks, streamBase: streamBase, token: token)
            return
        }
        queue = LocalQueue.insert(tracks, into: queue, playingAt: index, next: next)
        // `baseQueue` is the unshuffled order used to restore when shuffle goes
        // off. Unshuffled it mirrors the queue exactly; shuffled, new arrivals
        // simply join at the end — their "original" order is arrival order.
        baseQueue = shuffle
            ? baseQueue + tracks
            : LocalQueue.insert(tracks, into: baseQueue, playingAt: index, next: next)
        invalidateFollower()
        onStateChange?()
    }

    /// Remove queued tracks. Removing the playing track advances to the next
    /// survivor (keeping the play/pause state); removing everything stops.
    public func removeFromQueue(atOffsets offsets: IndexSet) {
        guard isEngaged else { return }
        let removed = offsets.sorted().compactMap { queue.indices.contains($0) ? queue[$0] : nil }
        guard !removed.isEmpty else { return }
        let update = LocalQueue.remove(atOffsets: offsets, from: queue, playingAt: index)
        queue = update.items
        // Drop one base-queue occurrence per removed track, so a queue holding
        // the same song twice loses only the copy the user actually swiped.
        for track in removed {
            if let i = baseQueue.firstIndex(where: { $0.id == track.id }) { baseQueue.remove(at: i) }
        }
        guard !queue.isEmpty else { stop(); return }
        if update.currentRemoved {
            load(index: update.index, autoPlay: isPlaying)
        } else {
            index = update.index
            invalidateFollower()
            onStateChange?()
        }
    }

    /// Reorder the queue (SwiftUI `onMove` offsets). Never interrupts playback —
    /// the playing track keeps going wherever it lands.
    public func moveInQueue(fromOffsets offsets: IndexSet, toOffset destination: Int) {
        guard isEngaged else { return }
        let update = LocalQueue.move(fromOffsets: offsets, toOffset: destination,
                                     in: queue, playingAt: index)
        queue = update.items
        // Only mirror into the base order when it IS the queue's order; a drag in
        // the shuffled view must not rewrite the order shuffle-off restores.
        if !shuffle { baseQueue = update.items }
        index = update.index
        invalidateFollower()
        onStateChange?()
    }

    /// Drop everything after the playing track — "wachtrij leegmaken" without
    /// interrupting what you're hearing. Stopping outright is a different verb
    /// (the Now Playing screen owns that one).
    public func clearUpcoming() {
        guard isEngaged, index + 1 < queue.count else { return }
        let dropped = Array(queue[(index + 1)...])
        queue = Array(queue.prefix(index + 1))
        if shuffle {
            // Shuffled, the base order is a different sequence — drop one
            // occurrence per removed track rather than truncating blindly.
            for track in dropped {
                if let i = baseQueue.firstIndex(where: { $0.id == track.id }) { baseQueue.remove(at: i) }
            }
        } else {
            baseQueue = queue
        }
        invalidateFollower()
        onStateChange?()
    }

    /// Play from here — the queue view's tap action.
    public func jump(to i: Int) {
        guard isEngaged, queue.indices.contains(i) else { return }
        load(index: i, autoPlay: true)
    }

    // MARK: - Internals
    //
    // Two ways a track starts. `load` is a HARD start — the user jumped, skipped
    // or the queue was rebuilt, so the player is emptied and refilled; a gap
    // there is expected and inaudible because the user caused it. The other way
    // is the automatic handover: `scheduleFollower` hands the next item to the
    // player while the current one still plays, so `AVQueuePlayer` crosses the
    // boundary with no reload. That path is the gapless one.

    private func load(index i: Int, autoPlay: Bool) {
        guard queue.indices.contains(i) else { return }
        #if canImport(AVFoundation)
        isRebuilding = true
        defer { isRebuilding = false }
        #endif
        index = i
        positionSec = 0
        durationSec = queue.indices.contains(i) ? (queue[i].durationSec ?? 0) : 0
        lastError = nil
        #if canImport(AVFoundation)
        fadeTask?.cancel()
        player.removeAllItems()
        scheduled = []
        guard let item = makeItem(for: queue[i]) else {
            lastError = CoreStrings.s("core.error.trackLoadFailed", "Kon dit nummer niet laden.")
            isPlaying = false
            onStateChange?()
            return
        }
        observeFailures(of: item)
        player.insert(item, after: nil)
        scheduled = [(index: i, item: item, hasMix: false)]
        applyLoudness(for: queue[i])   // also restores the level after a fade-out
        if autoPlay { player.play(); isPlaying = true } else { player.pause(); isPlaying = false }
        scheduleFollower()
        if autoPlay { onTrackChange?(queue[i]) }
        #endif
        onStateChange?()
    }

    #if canImport(AVFoundation)
    /// Hand the next track to the player *now*, while the current one is still
    /// playing — the whole point of `AVQueuePlayer`. Cheap and idempotent: does
    /// nothing when a follower is already queued or when the queue ends here.
    private func scheduleFollower() {
        guard isEngaged, scheduled.count == 1, let head = scheduled.first else { return }
        guard let nextIndex = LocalQueue.followerIndex(
            after: head.index, count: queue.count, loopMode: loopMode) else { return }
        guard let item = makeItem(for: queue[nextIndex]),
              player.canInsert(item, after: head.item) else { return }
        player.insert(item, after: head.item)
        scheduled.append((index: nextIndex, item: item, hasMix: false))
        attachLoudnessMix(to: item, for: queue[nextIndex])
    }

    /// The player moved to another item. Either it advanced by itself (the
    /// gapless handover — the new item is our scheduled follower) or the queue
    /// ran dry. A hard `load` also triggers this, but there the item is already
    /// the head, so it's a no-op beyond re-scheduling.
    private func handleCurrentItemChanged(to item: AVPlayerItem?) {
        // Ignore the churn `load` causes while it swaps items; only a genuine
        // handover or a queue that really ran dry should be acted on.
        guard isEngaged, !isRebuilding else { return }
        guard let item else {
            // Nothing left to play: the last track finished with no follower.
            stop()
            return
        }
        guard let position = scheduled.firstIndex(where: { $0.item === item }) else { return }
        scheduled.removeFirst(position)
        guard let head = scheduled.first else { return }
        if head.index != index {
            index = head.index
            positionSec = 0
            lastError = nil
            observeFailures(of: head.item)
            // The loudness gain rides on `player.volume`, which is per-player and
            // not per-item, so it can only change once the handover has happened
            // — a fraction of a second late. Inaudible for the small deltas
            // normalization produces, but it IS the mechanism behind the "click
            // between tracks" other clients report. Fixing it properly means a
            // per-item AVAudioMix; noted as a follow-up rather than done blind.
            if head.hasMix {
                // The item carries its own gain; the player must NOT apply it too.
                loudnessGain = 1
                reapplyVolume()
            } else {
                applyLoudness(for: queue[head.index])
            }
            onTrackChange?(queue[head.index])
            onStateChange?()
        }
        scheduleFollower()
    }
    #endif

    /// Drop the pre-enqueued follower and pick a new one. Any queue mutation
    /// (enqueue-next, remove, reorder, shuffle, repeat-mode change) can make the
    /// already-handed-over track the wrong one, and the player would happily
    /// play it — so every one of those verbs comes through here.
    private func invalidateFollower() {
        #if canImport(AVFoundation)
        guard isEngaged else { return }
        for entry in scheduled.dropFirst() { player.remove(entry.item) }
        scheduled = Array(scheduled.prefix(1))
        scheduleFollower()
        #endif
    }

    #if canImport(AVFoundation)
    /// Surface an asynchronous load failure. Without this a `/audio` error
    /// (bad/absent token → 401, missing on-disk file → 404, unsupported type →
    /// 415) fails silently: the engine stays engaged on a dead item, so the user
    /// hears nothing and sees no reason why. Here we stop, clear `isPlaying`, and
    /// publish a `lastError` the UI can show.
    private func observeFailures(of item: AVPlayerItem) {
        statusObserver?.invalidate()
        statusObserver = item.observe(\.status, options: [.new]) { [weak self] observed, _ in
            guard observed.status == .failed, let self else { return }
            // Read the (non-Sendable) item synchronously here, then hop to the
            // main actor with only Sendable values (the item's identity + code).
            // Capture `self` strongly (the engine is @MainActor, hence Sendable)
            // so the Task never references the mutable `weak var self`.
            let observedID = ObjectIdentifier(observed)
            let code = (observed.error as NSError?)?.code
            Task { @MainActor [self] in
                guard let current = self.player.currentItem,
                      ObjectIdentifier(current) == observedID else { return }
                self.reportLoadFailure(code: code)
            }
        }
    }

    private func reportLoadFailure(code: Int?) {
        isPlaying = false
        lastError = code.map {
            CoreStrings.f("core.error.trackPlayFailedCode",
                          "Kon dit nummer niet afspelen op dit apparaat (%d).", $0)
        } ?? CoreStrings.s("core.error.trackPlayFailed",
                           "Kon dit nummer niet afspelen op dit apparaat.")
        onStateChange?()
    }
    #endif

    /// Re-apply the loudness gain to the current item — call after the user
    /// changes the normalization settings so the change is audible immediately.
    public func reapplyLoudness() {
        #if canImport(AVFoundation)
        guard isEngaged, let track = current else { return }
        if scheduled.first?.hasMix == true {
            // This track's gain lives in its own mix. Re-applying it through the
            // player as well would square it — audibly quieter, not louder. The
            // mix can't be changed mid-track without a seek either, so the new
            // setting takes effect from the next track on.
            loudnessGain = 1
            reapplyVolume()
        } else {
            applyLoudness(for: track)
        }
        // The follower was handed over with a gain baked at the OLD setting —
        // rebuild it so the change is heard from the next track.
        invalidateFollower()
        #endif
    }

    #if canImport(AVFoundation)
    private func applyLoudness(for track: Track) {
        loudnessGain = LocalLoudness.volume(
            trackLufs: track.lufs, albumLufs: track.albumLufs,
            mode: LocalLoudness.mode, preampDB: LocalLoudness.preampDB)
        // Fold in the user volume so the slider and loudness normalization stack
        // instead of overwriting each other.
        reapplyVolume()
    }
    #endif

    #if canImport(AVFoundation)
    private func makeItem(for track: Track) -> AVPlayerItem? {
        // Qobuz (or any direct CDN URL): play it straight, no /audio server.
        if let override = track.streamURLOverride { return AVPlayerItem(url: override) }
        // Onderweg: ask the server for AAC instead of the original (policy-gated).
        let transcode = LocalTranscode.queryItems()
        let variant = LocalAudioCache.variant(for: transcode)
        // Already on disk from an earlier play: skip the network entirely. This
        // is what makes stepping back, repeating and replaying instant — and it
        // works with no server at all.
        // A pinned download wins over the opportunistic cache; both skip the
        // network entirely, which is what makes offline playback work at all.
        //
        // The URL that comes back carries a path extension, and it has to:
        // `AVURLAsset` reads the media type off the extension and does not sniff
        // content, so a bare-hash filename fails the whole asset with -12847
        // "This media format is not supported". Streaming hid that for months
        // because an HTTP response carries Content-Type — see
        // `LocalAudioCache.fileExtension(forHeader:)`.
        if let local = LocalAudioCache.localFile(forKey: track.id, variant: variant) {
            return AVPlayerItem(url: local)
        }
        var comps = URLComponents(string: "\(streamBase)/audio")
        // AVPlayer can't attach a custom auth header without private API, so the
        // token rides in the query (the /audio endpoint accepts both).
        var items = [URLQueryItem(name: "match_key", value: track.id)]
        if let token, !token.isEmpty { items.append(URLQueryItem(name: "token", value: token)) }
        items.append(contentsOf: transcode)
        comps?.queryItems = items
        guard let url = comps?.url else { return nil }
        fillCache(from: url, key: track.id, variant: variant)
        return AVPlayerItem(url: url)
    }

    /// Give the follower its loudness gain as a per-item `AVAudioMix`, so the
    /// level is already right the instant `AVQueuePlayer` crosses into it.
    ///
    /// Only for pre-enqueued items: there the async track load has seconds to
    /// finish. Unity gain needs no mix at all, which is the common case when a
    /// track has no measured LUFS. If the load is slow or fails, `hasMix` simply
    /// stays false and the handover falls back to the player-level route — the
    /// behaviour we had before, never worse.
    private func attachLoudnessMix(to item: AVPlayerItem, for track: Track) {
        let gain = LocalLoudness.volume(
            trackLufs: track.lufs, albumLufs: track.albumLufs,
            mode: LocalLoudness.mode, preampDB: LocalLoudness.preampDB)
        guard abs(gain - 1) > 0.001, let asset = item.asset as? AVURLAsset else { return }
        Task { @MainActor [weak self] in
            guard let audio = try? await asset.loadTracks(withMediaType: .audio).first else { return }
            let params = AVMutableAudioMixInputParameters(track: audio)
            params.setVolume(gain, at: .zero)
            let mix = AVMutableAudioMix()
            mix.inputParameters = [params]
            item.audioMix = mix
            guard let self, let i = self.scheduled.firstIndex(where: { $0.item === item }) else { return }
            self.scheduled[i].hasMix = true
        }
    }

    /// Populate the cache in the background so the *next* play of this track is
    /// local. Deliberately a second fetch rather than tapping the player's own
    /// stream: intercepting that needs an `AVAssetResourceLoaderDelegate` with
    /// range-request handling, which is a subsystem, not a cache.
    ///
    /// Skipped on an expensive path — doubling cellular data to warm a cache is
    /// exactly the wrong trade. (`NetworkPathMonitor` already drives the
    /// transcode policy, so the two agree on what "onderweg" means.)
    private func fillCache(from url: URL, key: String, variant: String) {
        guard LocalAudioCache.enabled, !key.isEmpty,
              !NetworkPathMonitor.shared.isExpensive else { return }
        Task.detached(priority: .utility) {
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  !data.isEmpty else { return }
            LocalAudioCache.store(data, forKey: key, variant: variant)
            LocalAudioCache.prune()
        }
    }
    #endif

    // MARK: - Audio session (iOS only; macOS plays without a session)

    private func activateSession() {
        #if os(iOS)
        let session = AVAudioSession.sharedInstance()
        // `.longFormAudio` marks this as a music/podcast session rather than
        // incidental audio: it's what lets iOS hand the session to AirPlay 2 and
        // CarPlay as a long-form route, and it's the documented setup for
        // continuous playlist playback. (The older `.longForm` spelling is
        // deprecated since iOS 13 — see AVAudioSessionTypes.h.)
        try? session.setCategory(.playback, mode: .default, policy: .longFormAudio)
        try? session.setActive(true)
        #endif
    }

    private func deactivateSession() {
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }
}
