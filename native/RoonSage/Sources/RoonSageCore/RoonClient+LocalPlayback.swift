import AudioAnalysis
import Foundation

/// "Phone as audio device": start on-device playback of library tracks, routed
/// through `LocalPlaybackController`. Tracks without an on-disk file (e.g.
/// Qobuz-only library entries) are dropped and reported via
/// `lastLocalPlaybackSummary` so the UI can show what was skipped.
@MainActor
extension RoonClient {
    /// Synthetic output id for "this device" in the zone/output picker.
    public static let localOutputID = "roonsage.local.device"

    // The display name for this output lives in RoonSageUI (`localOutputLabel`).
    // It used to be a hardcoded Dutch string here, which meant an English-language
    // app still read "Dit apparaat" — and being a literal rather than a key, the
    // localization gate could not catch it. Core owns the identity, the UI owns
    // the wording.

    /// SF Symbol for the on-device output in the output picker.
    public static var localOutputIcon: String {
        #if os(macOS)
        "laptopcomputer"
        #else
        "iphone"
        #endif
    }

    /// The on-device playback engine — the UI binds to its observable state.
    public var localPlayback: LocalPlaybackController { .shared }

    // `localOutputSelected` is a STORED, observable property on RoonClient (see
    // RoonClient.swift) — not a UserDefaults-backed computed one. It must be
    // observable: NowPlayingView keys its "local vs zone" branch on it, so a
    // non-observable value left the screen stale when you picked a zone (the
    // child OutputSelector updated, the outer branch didn't). Persistence to
    // UserDefaults happens in the property's didSet.

    /// Experimental: also stream Qobuz-in-library tracks to this device via
    /// Qobuz's unofficial API. Off by default (ToS-gray, needs the app_secret).
    public var qobuzLocalStreamEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "qobuz_local_stream_enabled") }
        set { UserDefaults.standard.set(newValue, forKey: "qobuz_local_stream_enabled") }
    }

    /// The Qobuz web-player `app_secret` used to sign streaming requests. Stored
    /// in the Keychain; the user pastes the current value (Qobuz rotates it).
    public var qobuzAppSecret: String? {
        get { KeychainStore.load(key: "qobuz_app_secret") }
        set {
            let v = (newValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if v.isEmpty { KeychainStore.delete(key: "qobuz_app_secret") }
            else { KeychainStore.save(key: "qobuz_app_secret", value: v) }
        }
    }

    /// Analyser base that serves `/audio` (and `/features`). Mirrors the feature
    /// sync's resolution: the configured analyzer URL, else the server host on
    /// the analyzer's default port.
    func localStreamBase() -> String {
        // Live connection first: featuresURL follows the host we're actually
        // connected over (LAN at home, ZeroTier on mobile data) — the stored
        // analyzer URL would pin /audio streaming to the LAN address.
        if isRemote, let base = remoteBaseURL { return featuresURL(serverBase: base) }
        if !analyzerURL.isEmpty { return analyzerURL }
        if let base = remoteBaseURL { return featuresURL(serverBase: base) }
        return ""
    }

    /// Partition a track list into locally-playable vs. blocked, without
    /// starting playback — lets a view preview the filter before committing.
    public func localPlayabilityPartition(_ tracks: [TrackRecord]) async -> LocalPlayability.Partition {
        guard let db = database else { return .init(playable: [], blocked: tracks) }
        let keys = (try? await db.playableMatchKeys()) ?? []
        return LocalPlayability.partition(tracks, playableKeys: keys)
    }

    /// Resolved input for the on-device engine: the stream base to fetch from,
    /// the playable tracks in their original order, and what got dropped.
    struct LocalPlaybackRequest {
        let base: String
        let items: [LocalPlaybackController.Track]
        let summary: LocalPlaybackSummary
    }

    /// Turn library records into engine tracks — drop what can't play here,
    /// attach loudness references, and (optionally) resolve Qobuz CDN URLs.
    /// Shared by every local verb so "speel" and "zet in de wachtrij" filter and
    /// normalize identically.
    ///
    /// Returns nil when there was nothing to try (empty input, no server); an
    /// empty `items` means everything was filtered out. Both paths have already
    /// set `lastActionError` / `lastLocalPlaybackSummary` for the UI.
    func resolveLocalPlayback(_ tracks: [TrackRecord]) async -> LocalPlaybackRequest? {
        guard !tracks.isEmpty else { return nil }
        let base = localStreamBase()
        guard !base.isEmpty else {
            lastActionError = ActionError(message: "Geen analyzer-server gevonden om lokaal af te spelen.")
            return nil
        }
        let part = await localPlayabilityPartition(tracks)
        let playableKeys = Set(part.playable.map { LocalPlayability.matchKey(for: $0) })

        // Optional experimental Qobuz fallback for the blocked (streaming-only)
        // tracks. Best-effort: any that don't resolve simply stay blocked.
        let qobuzURLs = await resolveQobuzStreams(for: part.blocked)

        // Loudness references for normalization (LMS-style, applied client-side).
        // Cheap lookups against the already-synced feature rows; empty maps when
        // nothing is measured — the engine then falls back to its assumed level.
        let allKeys = tracks.map { LocalPlayability.matchKey(for: $0) }
        let lufsByKey = await database?.loudnessByMatchKey(allKeys) ?? [:]
        let albumNames = Array(Set(tracks.compactMap { $0.album }))
        let albumLufs = await database?.albumMeanLoudness(albums: albumNames) ?? [:]

        // Build the queue in the ORIGINAL order, mixing local-file and Qobuz items.
        var items: [LocalPlaybackController.Track] = []
        var blockedTitles: [String] = []
        for rec in tracks {
            let key = LocalPlayability.matchKey(for: rec)
            let artist = rec.artist ?? "", album = rec.album ?? ""
            if playableKeys.contains(key) {
                items.append(.init(id: key, title: rec.title, artist: artist, album: album,
                                   imageKey: rec.imageKey, durationSec: nil,
                                   lufs: lufsByKey[key], albumLufs: albumLufs[album]))
            } else if let url = qobuzURLs[key] {
                items.append(.init(id: key, title: rec.title, artist: artist, album: album,
                                   imageKey: rec.imageKey, durationSec: nil, streamURLOverride: url,
                                   lufs: lufsByKey[key], albumLufs: albumLufs[album]))
            } else {
                blockedTitles.append(rec.title)
            }
        }
        let summary = LocalPlaybackSummary(
            requested: tracks.count, playable: items.count, blocked: blockedTitles.count,
            blockedExamples: Array(blockedTitles.prefix(3)))
        lastLocalPlaybackSummary = summary
        if items.isEmpty {
            lastActionError = ActionError(
                message: "Geen van deze nummers is hier af te spelen (Qobuz/stream, of niet op schijf).")
        }
        return LocalPlaybackRequest(base: base, items: items, summary: summary)
    }

    /// Start playing `tracks` on this device, dropping any that aren't locally
    /// playable. Records a `LocalPlaybackSummary` for the UI. Returns it (nil
    /// when there was nothing to resolve / no server).
    ///
    /// NOTED (pre-existing, not changed here): `startAt` indexes the resolved
    /// list, so it points at the wrong track when a blocked one precedes it.
    @discardableResult
    public func playLocally(_ tracks: [TrackRecord], startAt: Int = 0) async -> LocalPlaybackSummary? {
        guard let request = await resolveLocalPlayback(tracks) else { return nil }
        guard !request.items.isEmpty else { return request.summary }
        localOutputSelected = true
        localPlayback.play(request.items, streamBase: request.base,
                           token: LibraryShareServer.configuredToken, startAt: startAt)
        return request.summary
    }

    /// Add `tracks` to this device's queue — straight after the current track
    /// (`next: true`) or at the end. With nothing playing yet the engine treats
    /// it as "play these", so the verb always does something sensible.
    @discardableResult
    public func enqueueLocally(_ tracks: [TrackRecord], next: Bool) async -> LocalPlaybackSummary? {
        guard let request = await resolveLocalPlayback(tracks) else { return nil }
        guard !request.items.isEmpty else { return request.summary }
        localOutputSelected = true
        localPlayback.enqueue(request.items, streamBase: request.base,
                              token: LibraryShareServer.configuredToken, next: next)
        return request.summary
    }

    /// Resolve Qobuz CDN URLs for blocked tracks when the experimental toggle is
    /// on and credentials + app_secret are present. Returns [matchKey: URL].
    private func resolveQobuzStreams(for blocked: [TrackRecord]) async -> [String: URL] {
        guard qobuzLocalStreamEnabled, !blocked.isEmpty,
              let secret = qobuzAppSecret, !secret.isEmpty,
              let email = KeychainStore.load(key: "qobuz_email"), !email.isEmpty,
              let pw = KeychainStore.load(key: "qobuz_password"), !pw.isEmpty else { return [:] }
        let reqs = blocked.map {
            (key: LocalPlayability.matchKey(for: $0), title: $0.title, artist: $0.artist, album: $0.album)
        }
        return await QobuzClient.shared.streamURLs(for: reqs, appSecret: secret, email: email, password: pw)
    }

    /// Map a library-track row to a `TrackRecord` for local playback.
    private func record(_ t: DatabaseManager.LibraryTrackRow) -> TrackRecord {
        TrackRecord(id: t.id, title: t.title, artist: t.artist, album: t.album,
                    year: t.year, isLive: t.isLive)
    }

    // `playAlbumLocally` / `playArtistLocally` used to live here as the on-device
    // half of a pair, next to `playAlbum(zoneID:)` / `playArtist(zoneID:)`. They
    // are gone: those verbs now take an optional zone and route through
    // `deliver`, so there is one path per action instead of two. Removed once the
    // last caller was converted (2026-08-11) — the sweep found no other
    // references, in code or as strings.

    /// Make this device the active output. Future "play" actions route here (see
    /// `playToActiveOutput`) and the Now Playing screen shows the local player —
    /// even before anything is loaded. Selecting a Roon zone clears this again
    /// (`selectZone`).
    public func selectLocalOutput() {
        localOutputSelected = true
    }

    /// True when there's somewhere to play — a Roon zone or this device.
    public var hasActiveOutput: Bool { localOutputSelected || selectedZone != nil }

    /// Route on-device track changes into the same scrobble + listen-history path
    /// that zone playback has always used.
    ///
    /// Zone plays are logged from the zone-frame handler in `RoonClient`; local
    /// plays had no equivalent, so everything you listened to on the phone was
    /// invisible: no Last.fm scrobble, and no row in `listening_history`. That
    /// second one compounds — play counts feed the taste profile, "recent",
    /// "forgotten music" and the discovery seeding, so the longer you listened
    /// locally the more skewed those got.
    ///
    /// Idempotent: safe to call more than once, and the coordinator applies its
    /// own minimum-play gate before anything is actually submitted.
    func startLocalScrobbleBridge() {
        guard localPlayback.onTrackChange == nil else { return }
        localPlayback.onTrackChange = { [weak self] track in
            guard let self else { return }
            let item = ScrobbleCoordinator.Item(
                title: track.title,
                artist: track.artist.isEmpty ? nil : track.artist,
                album: track.album.isEmpty ? nil : track.album,
                length: track.durationSec,
                zoneID: Self.localOutputID,
                zoneName: "dit apparaat")
            let db = self.database
            Task { await self.scrobbler.trackChanged(item, database: db) }
        }
    }

    /// A track playing on the active output, flattened so callers don't care
    /// which output produced it.
    public struct ActiveTrack: Sendable, Equatable {
        public let title: String
        public let artist: String?
        public let album: String?
        public let imageKey: String?
        public let lengthSec: Int?
    }

    /// What is playing on the ACTIVE output — this device's engine when that's
    /// the chosen output, otherwise the selected Roon zone.
    ///
    /// Every feature that acts on "the track playing right now" (Live DJ, the DJ
    /// personas, the command palette, the ambient tint) used to read
    /// `selectedZone?.nowPlaying` directly. On this device that is nil, so those
    /// features quietly disabled themselves — Live DJ showed "start a track
    /// first" while a track was audibly playing.
    ///
    /// Precedence matches `NowPlayingBar`: audible local playback wins (you need
    /// to act on what you hear), an idle local output yields nil rather than
    /// falling through to a zone, and otherwise the zone answers.
    public var activeNowPlaying: ActiveTrack? {
        if let t = localPlayback.current, localPlayback.isEngaged {
            return ActiveTrack(title: t.title,
                               artist: t.artist.isEmpty ? nil : t.artist,
                               album: t.album.isEmpty ? nil : t.album,
                               imageKey: t.imageKey,
                               lengthSec: t.durationSec.map(Int.init))
        }
        guard !localOutputSelected, let np = selectedZone?.nowPlaying else { return nil }
        return ActiveTrack(title: np.title, artist: np.artist, album: np.album,
                           imageKey: np.imageKey, lengthSec: np.length)
    }

    /// Route a "play now" request to whichever output is active: on-device when
    /// selected, otherwise the selected Roon zone. Lets the primary play verbs
    /// (Speel alles / Speel nu) follow the chosen output instead of always
    /// targeting a zone.
    public func playToActiveOutput(_ tracks: [TrackRecord]) async {
        if localOutputSelected {
            await playLocally(tracks)
        } else if let zone = selectedZone {
            await curateTracks(tracks, zoneID: zone.id)
        }
    }

    /// Deliver an assembled track list: to a named Roon zone when the caller
    /// specifies one, otherwise to whatever output is active.
    ///
    /// This is what lets every "play these tracks" verb take `zoneID: String? =
    /// nil`. The UI omits it and follows the output picker; callers that
    /// genuinely address a zone by name — the MCP server, where an agent says
    /// "play this in the kitchen" — keep passing one and are unaffected.
    func deliver(_ tracks: [TrackRecord], to zoneID: String?) async {
        if let zoneID { await curateTracks(tracks, zoneID: zoneID) }
        else { await playToActiveOutput(tracks) }
    }

    /// `deliver`, for the append-to-queue verbs.
    func deliverToQueue(_ tracks: [TrackRecord], to zoneID: String?, next: Bool = false) async {
        if let zoneID { await queueTracks(tracks, next: next, zoneID: zoneID) }
        else { await queueToActiveOutput(tracks, next: next) }
    }

    /// Route a "queue" request to whichever output is active. The local engine
    /// gained insert-next/append, so the queue verbs are no longer Roon-only —
    /// "speel hierna" and "achteraan toevoegen" work on this device too.
    public func queueToActiveOutput(_ tracks: [TrackRecord], next: Bool) async {
        if localOutputSelected {
            await enqueueLocally(tracks, next: next)
        } else if let zone = selectedZone {
            await queueTracks(tracks, next: next, zoneID: zone.id)
        }
    }

    /// Stop on-device playback. Ends the session and clears the queue — but does
    /// NOT change where you listen.
    ///
    /// It used to also set `localOutputSelected = false`, from the era when
    /// listening here was a temporary detour you switched back out of. Now that
    /// this device is the default output, that made stopping a track silently
    /// hand your output back to a Roon zone — which is how the mini-player ended
    /// up advertising a zone's music. Changing output is the output picker's job
    /// (`selectZone` / `selectLocalOutput`), and only the user's.
    public func stopLocalPlayback() {
        localPlayback.stop()
    }

    /// Sleep-timer action: pause whatever is playing on this device — the local
    /// ("Deze iPhone") player if engaged, and the selected Roon zone if playing.
    public func pauseForSleep() async {
        // Ease out rather than cut: the sleep timer gets the long ramp.
        localPlayback.fadeOutAndPause(over: LocalPlaybackController.sleepFade)
        if let zone = selectedZone, zone.state == .playing {
            await playPause(zoneID: zone.id)
        }
    }
}
