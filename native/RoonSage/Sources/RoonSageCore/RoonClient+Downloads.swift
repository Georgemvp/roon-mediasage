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
        public var isFinished: Bool { completed + failed >= total }
        public var fraction: Double {
            total > 0 ? Double(completed + failed) / Double(total) : 0
        }
    }

    /// Pin `tracks` to this device, skipping anything already downloaded and
    /// anything that has no on-disk file on the server (Qobuz/stream-only).
    ///
    /// Reuses `resolveLocalPlayback`, so a download filters and names tracks
    /// exactly like playing them does — one definition of "can this play here".
    public func downloadForOffline(_ tracks: [TrackRecord]) async {
        guard downloadTask == nil else { return }   // one run at a time
        guard let request = await resolveLocalPlayback(tracks), !request.items.isEmpty else { return }

        let variant = LocalAudioCache.variant(for: LocalTranscode.queryItems())
        let pending = request.items.filter {
            LocalAudioCache.downloadedFile(forKey: $0.id, variant: variant) == nil
        }
        guard !pending.isEmpty else { return }

        let base = request.base
        let token = LibraryShareServer.configuredToken
        downloadProgress = DownloadProgress(total: pending.count, completed: 0, failed: 0,
                                            currentTitle: pending.first?.title)
        downloadTask = Task { [weak self] in
            var done = 0, failed = 0
            for item in pending {
                if Task.isCancelled { break }
                self?.downloadProgress = DownloadProgress(
                    total: pending.count, completed: done, failed: failed, currentTitle: item.title)
                let ok = await Self.fetchAndPin(item, base: base, token: token, variant: variant)
                if ok {
                    done += 1
                    await self?.database?.recordOfflineTrack(
                        matchKey: item.id, variant: variant, title: item.title,
                        artist: item.artist.isEmpty ? nil : item.artist,
                        album: item.album.isEmpty ? nil : item.album,
                        imageKey: item.imageKey,
                        bytes: LocalAudioCache.downloadedFile(forKey: item.id, variant: variant)
                            .flatMap { (try? $0.resourceValues(forKeys: [.fileSizeKey]))?.fileSize } ?? 0)
                } else {
                    failed += 1
                }
            }
            self?.downloadProgress = DownloadProgress(
                total: pending.count, completed: done, failed: failed, currentTitle: nil)
            self?.downloadTask = nil
            await self?.refreshOfflineKeys()
            if failed > 0 {
                self?.lastActionError = ActionError(
                    message: "\(failed) van \(pending.count) nummers konden niet worden opgeslagen.")
            }
        }
    }

    /// One track, fetched whole. `nonisolated static` so the transfer itself
    /// never occupies the main actor.
    private nonisolated static func fetchAndPin(
        _ item: LocalPlaybackController.Track, base: String, token: String?, variant: String
    ) async -> Bool {
        // A Qobuz item plays from a signed CDN URL that expires; pinning it would
        // produce a file that stops working. Only on-disk library audio is pinnable.
        guard item.streamURLOverride == nil else { return false }
        var comps = URLComponents(string: "\(base)/audio")
        var q = [URLQueryItem(name: "match_key", value: item.id)]
        if let token, !token.isEmpty { q.append(URLQueryItem(name: "token", value: token)) }
        q.append(contentsOf: LocalTranscode.queryItems())
        comps?.queryItems = q
        guard let url = comps?.url else { return false }
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return false }
        return LocalAudioCache.storeDownload(data, forKey: item.id, variant: variant)
    }

    public func cancelDownloads() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadProgress = nil
    }

    /// Remove one track's download (file + bookkeeping).
    public func removeOfflineTrack(matchKey: String) async {
        let variant = LocalAudioCache.variant(for: LocalTranscode.queryItems())
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
}
