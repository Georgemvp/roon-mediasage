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
    public var durationSec: Double {
        #if canImport(AVFoundation)
        if let item = player.currentItem {
            let d = item.duration.seconds
            if d.isFinite, d > 0 { return d }
        }
        #endif
        return current?.durationSec ?? 0
    }

    /// Set by the iOS app so it can refresh `MPNowPlayingInfoCenter` and the
    /// home-screen widget whenever the engine's state changes. Kept as a closure
    /// so this core type never imports MediaPlayer. `@MainActor` so the handler
    /// can touch main-actor UI/system state directly.
    public var onStateChange: (@MainActor () -> Void)?

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
    @ObservationIgnored private var scheduled: [(index: Int, item: AVPlayerItem)] = []
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var currentItemObserver: NSKeyValueObservation?
    /// Watches the current item's `status` so a server-side failure surfaces as a
    /// visible error instead of a silent "engaged but no sound".
    @ObservationIgnored private var statusObserver: NSKeyValueObservation?
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
        player.volume = loudnessGain * Float(isMuted ? 0 : volume)
        #endif
    }

    public func togglePlayPause() {
        #if canImport(AVFoundation)
        guard isEngaged else { return }
        if isPlaying { player.pause(); isPlaying = false }
        else { player.play(); isPlaying = true }
        onStateChange?()
        #endif
    }

    /// User-pressed Next: always steps forward, even under "repeat one" (where
    /// the automatic follower is the same track again). "loop" wraps at the end;
    /// otherwise the session stops.
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
        index = i
        positionSec = 0
        lastError = nil
        #if canImport(AVFoundation)
        player.removeAllItems()
        scheduled = []
        guard let item = makeItem(for: queue[i]) else {
            lastError = "Kon dit nummer niet laden."
            isPlaying = false
            onStateChange?()
            return
        }
        observeFailures(of: item)
        player.insert(item, after: nil)
        scheduled = [(index: i, item: item)]
        applyLoudness(for: queue[i])
        if autoPlay { player.play(); isPlaying = true } else { player.pause(); isPlaying = false }
        scheduleFollower()
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
        scheduled.append((index: nextIndex, item: item))
    }

    /// The player moved to another item. Either it advanced by itself (the
    /// gapless handover — the new item is our scheduled follower) or the queue
    /// ran dry. A hard `load` also triggers this, but there the item is already
    /// the head, so it's a no-op beyond re-scheduling.
    private func handleCurrentItemChanged(to item: AVPlayerItem?) {
        guard isEngaged else { return }
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
            applyLoudness(for: queue[head.index])
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
        lastError = code.map { "Kon dit nummer niet afspelen op dit apparaat (\($0))." }
            ?? "Kon dit nummer niet afspelen op dit apparaat."
        onStateChange?()
    }
    #endif

    /// Re-apply the loudness gain to the current item — call after the user
    /// changes the normalization settings so the change is audible immediately.
    public func reapplyLoudness() {
        #if canImport(AVFoundation)
        guard isEngaged, let track = current else { return }
        applyLoudness(for: track)
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
        var comps = URLComponents(string: "\(streamBase)/audio")
        // AVPlayer can't attach a custom auth header without private API, so the
        // token rides in the query (the /audio endpoint accepts both).
        var items = [URLQueryItem(name: "match_key", value: track.id)]
        if let token, !token.isEmpty { items.append(URLQueryItem(name: "token", value: token)) }
        // Onderweg: ask the server for AAC instead of the original (policy-gated).
        items.append(contentsOf: LocalTranscode.queryItems())
        comps?.queryItems = items
        guard let url = comps?.url else { return nil }
        return AVPlayerItem(url: url)
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
