import SwiftUI
import RoonSageCore

/// Where the music comes out, as far as the Now Playing screen is concerned.
///
/// There used to be two full-screen players: `LocalNowPlayingScreen` for
/// on-device playback and `NowPlayingHero` for a Roon zone. They drew the same
/// thing from two sets of bindings, 1.421 lines between them, and were aligned
/// by hand twice (v1.10.229 and v1.10.260) — the second time only because a
/// screenshot showed the zone screen still wearing the old layout. A third
/// divergence was a matter of when, not if.
///
/// So the difference between the two outputs lives here instead, as data:
/// what's playing, what the transport does, and **what this output can't do**.
/// `PlayerScreen` renders whatever a surface reports and hides what it lacks,
/// rather than two screens each deciding for themselves.
///
/// Everything is read on demand (computed properties over the live client), so
/// SwiftUI's observation still sees `localPlayback.positionSec` or the zone
/// value it came from — wrapping them in a snapshot struct would have severed
/// exactly that.
@MainActor
protocol NowPlayingSurface {
    /// Identifies the OUTPUT, not the track. `PlayerScreen` keys its view state
    /// on this, so switching output resets the scrubber and volume state the way
    /// swapping between two separate screens used to.
    var surfaceID: String { get }

    // MARK: What's playing

    /// Raw title — feature and feedback lookups match on it, so it must NOT be
    /// pre-formatted. The screen applies `.displayTitle` where it renders.
    var title: String? { get }
    var artist: String? { get }
    var album: String? { get }
    var imageKey: String? { get }

    // MARK: Transport state

    var isPlaying: Bool { get }
    var positionSec: Double { get }
    var durationSec: Double { get }

    /// True when the engine itself publishes a live position (the local player
    /// does, at 2 Hz). False when it only refreshes on a server poll, in which
    /// case `PlayerScreen` interpolates from a wall-clock anchor in between —
    /// see `NowPlayingModel.interpolatedPosition`.
    var positionIsContinuous: Bool { get }

    var shuffle: Bool { get }
    var loopMode: String { get }

    // MARK: Capabilities

    /// The in-app volume control, or nil when this output has none.
    var volume: PlayerVolume? { get }

    /// iOS on-device playback shows the SYSTEM volume (`MPVolumeView`) instead
    /// of an app-level slider: an app slider attenuates on top of the device
    /// volume, so the hardware buttons and Control Center would disagree with
    /// what the app shows.
    var usesSystemVolume: Bool { get }

    /// Sonic Radio is a Roon-zone verb for now. Journey works on both.
    var supportsSonicRadio: Bool { get }

    /// Which now-playing track the karaoke view should follow.
    var lyricsSource: LyricsView.Source { get }

    // MARK: Extras only one output has

    /// Playback error from the on-device engine (a stream that wouldn't open).
    var errorMessage: String? { get }
    /// "3 of 5 playable here" — what the local engine had to skip.
    var statusNote: String? { get }
    /// Shown under "nothing playing": the zone's name. Nil on this device,
    /// where the output selector above already says where you are.
    var idleSubtitle: String? { get }

    var upNext: PlayerUpNext? { get }

    // MARK: Actions

    func toggle()
    func next()
    func previous()
    func seek(toSeconds seconds: Double)
    func setShuffle(_ on: Bool)
    func setLoop(_ mode: String)
    func startSonicRadio() async
    func startJourney() async
}

extension NowPlayingSurface {
    /// Identity for `.task(id:)`: re-read the analyzer's features when the track
    /// OR the output changes, and not on every position tick.
    var featureKey: String {
        "\(surfaceID)|\(title ?? "")|\(artist ?? "")|\(album ?? "")"
    }

    var hasTrack: Bool { title != nil }
}

// MARK: - Supporting values

/// One in-app volume control, normalised across a Roon output (integer steps in
/// a device-reported range) and the local engine (0…1 gain shown as 0…100).
struct PlayerVolume {
    var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var isMuted: Bool
    var set: @MainActor (Double) -> Void
    var toggleMute: @MainActor () -> Void

    /// The number next to the slider — 0 while muted, so the readout matches
    /// what you hear rather than what the level would be.
    var readout: Int { isMuted ? 0 : Int(value.rounded()) }
}

/// The track after this one, for the "up next" pill.
struct PlayerUpNext {
    var title: String
    var subtitle: String?
    var imageKey: String?
}

// MARK: - On-device output

/// The local `AVQueuePlayer` engine as a Now Playing surface.
@MainActor
struct LocalNowPlayingSurface: NowPlayingSurface {
    let client: RoonClient

    private var lp: LocalPlaybackController { client.localPlayback }

    var surfaceID: String { "local" }

    var title: String? { lp.current?.title }
    // The local engine stores empty strings where Roon reports nil; normalise,
    // so a missing artist reads the same to the screen from either output.
    var artist: String? { lp.current?.artist.nilIfEmpty }
    var album: String? { lp.current?.album.nilIfEmpty }
    var imageKey: String? { lp.current?.imageKey }

    var isPlaying: Bool { lp.isPlaying }
    var positionSec: Double { lp.positionSec }
    var durationSec: Double { lp.durationSec }
    var positionIsContinuous: Bool { true }

    var shuffle: Bool { lp.shuffle }
    var loopMode: String { lp.loopMode }

    var volume: PlayerVolume? {
        #if os(iOS)
        // The system slider carries it; no app-level level to expose.
        return nil
        #else
        return PlayerVolume(
            value: lp.volume * 100,
            range: 0...100,
            step: 1,
            isMuted: lp.isMuted,
            set: { lp.setVolume($0 / 100) },
            toggleMute: { lp.toggleMute() }
        )
        #endif
    }

    var usesSystemVolume: Bool {
        #if os(iOS)
        true
        #else
        false
        #endif
    }

    /// Deliberately false for now: enabling it is a behaviour change, not a
    /// refactor, and it gets its own commit. (`playSonicRadio(zoneID: nil)`
    /// already routes to the active output, so the verb itself is ready.)
    var supportsSonicRadio: Bool { false }

    var lyricsSource: LyricsView.Source { .device }

    var errorMessage: String? { lp.lastError }

    var statusNote: String? {
        guard let s = client.lastLocalPlaybackSummary, s.blocked > 0 else { return nil }
        return String(format: LS("nowPlaying.blockedSummary"), s.playable, s.requested, s.blocked)
    }

    var idleSubtitle: String? { nil }

    var upNext: PlayerUpNext? {
        guard lp.queue.indices.contains(lp.index + 1) else { return nil }
        let t = lp.queue[lp.index + 1]
        return PlayerUpNext(title: t.title, subtitle: t.artist.nilIfEmpty, imageKey: t.imageKey)
    }

    func toggle() { lp.togglePlayPause() }
    func next() { lp.next() }
    func previous() { lp.previous() }
    func seek(toSeconds seconds: Double) { lp.seek(toSeconds: seconds) }
    func setShuffle(_ on: Bool) { lp.setShuffle(on) }
    func setLoop(_ mode: String) { lp.setLoop(mode) }

    func startSonicRadio() async {
        guard let t = lp.current else { return }
        await client.playSonicRadio(title: t.title, artist: t.artist.nilIfEmpty,
                                    album: t.album.nilIfEmpty)
    }

    func startJourney() async {
        guard let t = lp.current else { return }
        await client.playSonicAdventure(title: t.title, artist: t.artist.nilIfEmpty,
                                        album: t.album.nilIfEmpty)
    }
}

// MARK: - Roon zone output

/// A selected Roon zone as a Now Playing surface.
@MainActor
struct ZoneNowPlayingSurface: NowPlayingSurface {
    let client: RoonClient
    let zone: Zone

    private var np: NowPlaying? { zone.nowPlaying }
    private var output: Output? { zone.outputs.first }

    var surfaceID: String { "zone:\(zone.id)" }

    var title: String? { np?.title }
    var artist: String? { np?.artist }
    var album: String? { np?.album }
    var imageKey: String? { np?.imageKey }

    var isPlaying: Bool { zone.state == .playing }
    var positionSec: Double { zone.seekPosition ?? 0 }
    var durationSec: Double { Double(np?.length ?? 0) }
    /// Roon reports a position per poll, not continuously.
    var positionIsContinuous: Bool { false }

    var shuffle: Bool { zone.shuffle ?? false }
    var loopMode: String { zone.loopMode ?? "disabled" }

    var volume: PlayerVolume? {
        guard let output, let vol = output.volume else { return nil }
        let outputID = output.id
        return PlayerVolume(
            value: Double(vol.value),
            range: Double(vol.min)...Double(max(vol.max, vol.min + 1)),
            step: Double(max(vol.step, 1)),
            isMuted: vol.isMuted,
            set: { [client] v in
                Task { await client.setVolume(outputID: outputID, value: Int(v)) }
            },
            toggleMute: { [client] in
                Task { await client.toggleMute(outputID: outputID, muted: !vol.isMuted) }
            }
        )
    }

    var usesSystemVolume: Bool { false }
    var supportsSonicRadio: Bool { true }
    var lyricsSource: LyricsView.Source { .zone(zone) }

    var errorMessage: String? { nil }
    var statusNote: String? { nil }
    var idleSubtitle: String? { zone.displayName }

    var upNext: PlayerUpNext? {
        guard client.queueItems.count > 1 else { return nil }
        let item = client.queueItems[1]
        return PlayerUpNext(title: item.title, subtitle: item.subtitle, imageKey: item.imageKey)
    }

    func toggle() { Task { await client.playPause(zoneID: zone.id) } }
    func next() { Task { await client.next(zoneID: zone.id) } }
    func previous() { Task { await client.previous(zoneID: zone.id) } }
    func seek(toSeconds seconds: Double) { Task { await client.seek(zoneID: zone.id, seconds: seconds) } }
    func setShuffle(_ on: Bool) { Task { await client.setShuffle(zoneID: zone.id, enabled: on) } }
    func setLoop(_ mode: String) { Task { await client.setRepeat(zoneID: zone.id, mode: mode) } }

    func startSonicRadio() async {
        guard let np else { return }
        await client.playSonicRadio(title: np.title, artist: np.artist,
                                    album: np.album, zoneID: zone.id)
    }

    func startJourney() async {
        guard let np else { return }
        await client.playSonicAdventure(title: np.title, artist: np.artist,
                                        album: np.album, zoneID: zone.id)
    }
}


// MARK: - Helper

extension String {
    /// An empty string is "no value" as far as this screen is concerned.
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
