import Foundation
import Observation

/// "Neem dit mee" — pinning library audio to this device so it plays with no
/// server and no signal.
///
/// This is the tier the playback cache (`LocalAudioCache`) deliberately is not:
/// the cache fills with whatever you happened to play and is LRU-pruned, so it
/// can never answer "I want this album on the plane". Downloads are explicit,
/// live outside Caches/, and are never pruned — only you remove them.
///
/// Sequential on purpose. Parallel fetches of 30–40 MB FLAC files would saturate
/// the link the player is streaming over, so a download in the background would
/// stutter the music you're listening to right now.
@MainActor
extension RoonClient {

    /// Live progress for the downloads UI. `nil` when nothing is running.
    public struct DownloadProgress: Sendable, Equatable {
        public let total: Int
        public let completed: Int
        public let failed: Int
        public let currentTitle: String?
        /// How far the track in flight has got, 0…1. Without it the bar moved
        /// only once per finished track, so a five-track album showed four
        /// motionless minutes — the exact reading a stuck download gives.
        public let currentFraction: Double
        public var isFinished: Bool { completed + failed >= total }
        public var fraction: Double {
            total > 0 ? (Double(completed + failed) + currentFraction) / Double(total) : 0
        }
    }

    /// Wire the engine's callbacks into this client's observable state. Called
    /// once per launch; also brings a background session left running by a
    /// previous launch back up, so a queue that finished while the app was
    /// suspended reports in and gets its bookkeeping rows.
    public func startOfflineDownloads() {
        guard !offlineDownloadsStarted else { return }
        offlineDownloadsStarted = true
        let manager = OfflineDownloadManager.shared
        manager.onChange = { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.downloadProgress = snapshot.map {
                    DownloadProgress(total: $0.total, completed: $0.completed, failed: $0.failed,
                                     currentTitle: $0.currentTitle, currentFraction: $0.currentFraction)
                }
                // One summary when the queue drains, not a banner per failed
                // track: a queued album can fail forty times, and forty banners
                // say less than "12 van 40 konden niet worden opgeslagen".
                if let s = snapshot, s.isFinished, s.failed > 0 {
                    self.lastActionError = ActionError(
                        message: CoreStrings.f("core.error.downloadPartialFail",
                                               "%d van %d nummers konden niet worden opgeslagen.",
                                               s.failed, s.total))
                }
            }
        }
        manager.onFinished = { [weak self] item, filename, bytes in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let filename else { return }   // the summary above reports failures
                await self.database?.recordOfflineTrack(
                    matchKey: item.matchKey,
                    variant: LocalAudioCache.variant(for: LocalTranscode.queryItems()),
                    title: item.title, artist: item.artist, album: item.album,
                    imageKey: item.imageKey, bytes: bytes, localPath: filename)
                await self.refreshOfflineKeys()
            }
        }
        manager.reattach()
    }

    /// Pin `tracks` to this device, skipping anything already downloaded and
    /// anything that has no on-disk file on the server (Qobuz/stream-only).
    ///
    /// Reuses `resolveLocalPlayback`, so a download filters and names tracks
    /// exactly like playing them does — one definition of "can this play here".
    ///
    /// Appends to the queue rather than refusing while one runs: asking for a
    /// second album used to do nothing at all, with no explanation.
    public func downloadForOffline(_ tracks: [TrackRecord]) async {
        // The largest transfer this app makes. Refuse it on an expensive path
        // unless the user deliberately allowed it — taking music with you is
        // something you do before you leave, not something that quietly empties
        // your bundle on the train.
        if NetworkPathMonitor.shared.isExpensive, !LocalAudioCache.downloadOnCellular {
            lastActionError = ActionError(
                message: CoreStrings.s("core.error.downloadOnCellular",
                                       "Niet gedownload: je zit op mobiele data. Zet het aan bij Instellingen → Downloads, of wacht op wifi."))
            return
        }
        startOfflineDownloads()
        guard let request = await resolveLocalPlayback(tracks), !request.items.isEmpty else { return }

        let variant = LocalAudioCache.variant(for: LocalTranscode.queryItems())
        let manager = OfflineDownloadManager.shared
        let pending = request.items.filter { item in
            // A Qobuz item plays from a signed CDN URL that expires; pinning it
            // would produce a file that stops working. Only on-disk library
            // audio is pinnable.
            item.streamURLOverride == nil
                && LocalAudioCache.downloadedFile(forKey: item.id, variant: variant) == nil
                && manager.status(forKey: item.id) == nil
        }
        guard !pending.isEmpty else { return }

        manager.enqueue(pending.map {
            OfflineDownloadManager.Item(matchKey: $0.id, title: $0.title,
                                        artist: $0.artist.isEmpty ? nil : $0.artist,
                                        album: $0.album.isEmpty ? nil : $0.album,
                                        imageKey: $0.imageKey)
        }, base: request.base, token: LibraryShareServer.configuredToken, variant: variant)
    }

    /// Where a track sits in the queue, for the arrow on a library row. `nil`
    /// means neither queued nor downloading — check `isDownloaded` for whether
    /// it is already here.
    public func downloadStatus(for track: TrackRecord) -> OfflineDownloadManager.Status? {
        OfflineDownloadManager.shared.status(forKey: LocalPlayability.matchKey(for: track))
    }

    public func cancelDownloads() {
        OfflineDownloadManager.shared.cancelAll()
        downloadProgress = nil
    }

    /// Remove one track's download (file + bookkeeping).
    public func removeOfflineTrack(matchKey: String) async {
        // The stored variant, not the current policy's — see `offlineVariant`.
        let variant = await database?.offlineVariant(matchKey: matchKey)
            ?? LocalAudioCache.variant(for: LocalTranscode.queryItems())
        LocalAudioCache.removeDownload(forKey: matchKey, variant: variant)
        await database?.deleteOfflineTrack(matchKey: matchKey)
        await refreshOfflineKeys()
    }

    public func removeAllOfflineTracks() async {
        LocalAudioCache.clearDownloads()
        await database?.deleteAllOfflineTracks()
        await refreshOfflineKeys()
    }

    /// Re-read which tracks are pinned, so rows can show an "offline" mark
    /// without hitting the filesystem per row.
    public func refreshOfflineKeys() async {
        offlineKeys = Set((try? await database?.offlineTrackKeys()) ?? [])
    }

    /// Is this record already on the device?
    public func isDownloaded(_ track: TrackRecord) -> Bool {
        offlineKeys.contains(LocalPlayability.matchKey(for: track))
    }

    // MARK: - "Houd favorieten offline"

    /// UserDefaults key the settings toggle binds to, so the screen and this
    /// code never disagree about which flag they mean.
    public static let keepFavoritesOfflineKey = "keep_favorites_offline"

    public static var keepFavoritesOffline: Bool {
        get { UserDefaults.standard.bool(forKey: keepFavoritesOfflineKey) }
        set { UserDefaults.standard.set(newValue, forKey: keepFavoritesOfflineKey) }
    }

    /// Queue anything you have starred that is not on the device yet.
    ///
    /// **Starred ALBUMS only.** A starred artist is a statement about an artist,
    /// not a request for their discography — this library has artists with 217
    /// albums, and quietly pinning all of them is how a setting fills a phone.
    ///
    /// Nothing is ever removed here: un-starring an album does not delete a
    /// download. Deleting a user's file because they changed a star is a
    /// surprise in the one direction that cannot be undone offline; the
    /// Downloads screen is where removal lives.
    ///
    /// Idempotent and cheap once converged — `downloadForOffline` filters out
    /// everything already stored or queued, so a run with nothing to do enqueues
    /// nothing.
    public func syncFavoritesOffline() async {
        guard Self.keepFavoritesOffline, let db = database else { return }
        // Same expensive-path rule as a manual download; `downloadForOffline`
        // would refuse anyway, but silently and with an error banner the user
        // never asked to see.
        if NetworkPathMonitor.shared.isExpensive, !LocalAudioCache.downloadOnCellular { return }

        await ensureFavoritesLoaded()
        guard let favorites = try? await db.allFavorites() else { return }
        let albums = favorites
            .filter { $0.kind == FavoriteKind.album.rawValue }
            .map { (album: $0.title ?? "", artist: $0.artist) }
            .filter { !$0.album.isEmpty }
        guard !albums.isEmpty else { return }

        guard let tracks = try? await db.tracksForFavoriteAlbums(albums), !tracks.isEmpty else { return }
        let missing = tracks.filter { !isDownloaded($0) }
        guard !missing.isEmpty else { return }
        Log.info("Favorieten offline: \(missing.count) nummers in de wachtrij", category: .network)
        await downloadForOffline(missing)
    }
}
