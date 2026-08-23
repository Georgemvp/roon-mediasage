import Foundation

/// The transfer engine behind "Neem dit mee".
///
/// Split out of `RoonClient+Downloads` for one concrete reason: downloads used
/// to run on `URLSession.data(from:)` from an `@MainActor` task, which meant
/// (a) a whole 30–40 MB FLAC went through RAM per track, and (b) the queue died
/// the moment iOS suspended the app — so "download this album before I leave"
/// only worked if you kept looking at the screen. A background
/// `URLSessionDownloadTask` survives suspension and streams to disk, and the
/// system resumes the app to finish the bookkeeping.
///
/// Still strictly sequential. Parallel fetches of 30–40 MB files saturate the
/// same link the player is streaming over, so a background download would
/// stutter the music you are listening to right now. The queue is the point;
/// the concurrency is not.
///
/// No UIKit/AppKit: this is `RoonSageCore` and has to build for both platforms.
/// The iOS app forwards its `handleEventsForBackgroundURLSession` callback into
/// `backgroundCompletionHandler`.
public final class OfflineDownloadManager: NSObject, @unchecked Sendable {

    public static let shared = OfflineDownloadManager()

    /// Must be stable across launches — it is how the OS reattaches a running
    /// background session to a relaunched process.
    public static let sessionIdentifier = "com.roonsage.offline-downloads"

    /// One queued track. Deliberately not `TrackRecord`: the queue survives a
    /// process restart in spirit, and everything here is what the bookkeeping
    /// row needs, nothing more.
    public struct Item: Sendable, Equatable {
        public let matchKey: String
        public let title: String
        public let artist: String?
        public let album: String?
        public let imageKey: String?

        public init(matchKey: String, title: String, artist: String?, album: String?, imageKey: String?) {
            self.matchKey = matchKey
            self.title = title
            self.artist = artist
            self.album = album
            self.imageKey = imageKey
        }
    }

    /// What a row shows next to a track.
    public enum Status: Sendable, Equatable {
        case queued
        case downloading(fraction: Double)
        case done
    }

    /// The whole queue in one value, for the progress bar in Settings.
    public struct Snapshot: Sendable, Equatable {
        public let total: Int
        public let completed: Int
        public let failed: Int
        public let currentTitle: String?
        public let currentFraction: Double
        public var isFinished: Bool { completed + failed >= total }
        public var fraction: Double {
            total > 0 ? (Double(completed + failed) + currentFraction) / Double(total) : 0
        }
    }

    /// Called on every queue change. Set by `RoonClient`, which hops to the main
    /// actor — the delegate callbacks arrive on URLSession's own queue.
    public var onChange: (@Sendable (Snapshot?) -> Void)?

    /// Called once per finished track with the stored filename (nil = failed),
    /// so the caller can write the bookkeeping row.
    public var onFinished: (@Sendable (Item, String?, Int) -> Void)?

    /// Set by the iOS app from `application(_:handleEventsForBackgroundURLSession:completionHandler:)`.
    /// Invoked once the session has replayed everything it finished while the
    /// app was suspended; not calling it makes the OS kill the app.
    public var backgroundCompletionHandler: (@Sendable () -> Void)?

    // MARK: - State (guarded by `lock`)

    private let lock = NSLock()
    private var pending: [Item] = []
    private var active: (item: Item, task: URLSessionDownloadTask)?
    private var completed = 0
    private var failed = 0
    private var total = 0
    private var currentFraction: Double = 0
    private var variant = "orig"
    private var base = ""
    private var token: String?
    /// Per-key status for the row indicators — cleared as the queue drains.
    private var statuses: [String: Status] = [:]

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        // The user asked for this transfer; it should not wait for the system to
        // decide the moment is opportune.
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        // Cellular is gated in `RoonClient.downloadForOffline` by the user's own
        // setting, which is a policy decision the session must not second-guess.
        config.allowsCellularAccess = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Bring the session up so a queue left running by a previous launch
    /// reattaches and reports in. Cheap and idempotent.
    public func reattach() { _ = session }

    // MARK: - Queue

    /// Append `items` and start the queue if it is idle.
    ///
    /// `base`/`token`/`variant` are captured per call rather than read from
    /// globals in the delegate: the network can change hosts mid-queue, and a
    /// download half-fetched from the LAN address and half from the ZeroTier one
    /// is not a file.
    public func enqueue(_ items: [Item], base: String, token: String?, variant: String) {
        guard !items.isEmpty else { return }
        lock.lock()
        self.base = base
        self.token = token
        self.variant = variant
        pending.append(contentsOf: items)
        total += items.count
        for item in items where statuses[item.matchKey] == nil {
            statuses[item.matchKey] = .queued
        }
        lock.unlock()
        publish()
        startNextIfIdle()
    }

    public func cancelAll() {
        lock.lock()
        pending.removeAll()
        let running = active?.task
        active = nil
        total = 0; completed = 0; failed = 0; currentFraction = 0
        statuses.removeAll()
        lock.unlock()
        running?.cancel()
        onChange?(nil)
    }

    /// Status for one track, or nil when it is neither queued nor downloading.
    /// "Already on disk" is answered by `RoonClient.offlineKeys`, not here — the
    /// queue forgets a track as soon as it is done.
    public func status(forKey key: String) -> Status? {
        lock.lock(); defer { lock.unlock() }
        return statuses[key]
    }

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return active != nil || !pending.isEmpty
    }

    private func startNextIfIdle() {
        lock.lock()
        guard active == nil, !pending.isEmpty else { lock.unlock(); return }
        let item = pending.removeFirst()
        guard let request = Self.request(for: item, base: base, token: token, variant: variant) else {
            // An unbuildable URL is a permanent failure for this item, never a
            // reason to stall the rest of the queue.
            failed += 1
            statuses[item.matchKey] = nil
            lock.unlock()
            onFinished?(item, nil, 0)
            publish()
            startNextIfIdle()
            return
        }
        let task = session.downloadTask(with: request)
        // The only channel that survives a process restart: on relaunch the
        // delegate gets tasks back, not the Swift values that created them.
        task.taskDescription = item.matchKey
        active = (item, task)
        currentFraction = 0
        statuses[item.matchKey] = .downloading(fraction: 0)
        lock.unlock()
        task.resume()
        publish()
    }

    private static func request(for item: Item, base: String, token: String?, variant: String) -> URLRequest? {
        var comps = URLComponents(string: "\(base)/audio")
        var query = [URLQueryItem(name: "match_key", value: item.matchKey)]
        if let token, !token.isEmpty { query.append(URLQueryItem(name: "token", value: token)) }
        // `variant` is exactly the query string `LocalAudioCache.variant(for:)`
        // hashes the file under, so re-deriving the items from it keeps the
        // requested bytes and the storage key in step by construction.
        if variant != "orig" {
            for pair in variant.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                guard kv.count == 2 else { continue }
                query.append(URLQueryItem(name: String(kv[0]), value: String(kv[1])))
            }
        }
        comps?.queryItems = query
        guard let url = comps?.url else { return nil }
        return URLRequest(url: url)
    }

    private func publish() {
        lock.lock()
        let snapshot = total > 0
            ? Snapshot(total: total, completed: completed, failed: failed,
                       currentTitle: active?.item.title, currentFraction: currentFraction)
            : nil
        lock.unlock()
        onChange?(snapshot)
    }

    /// Finish one item and move on. `filename` nil = it failed.
    private func finish(_ item: Item, filename: String?, bytes: Int) {
        lock.lock()
        if filename != nil { completed += 1 } else { failed += 1 }
        statuses[item.matchKey] = nil
        active = nil
        currentFraction = 0
        let drained = pending.isEmpty
        lock.unlock()

        onFinished?(item, filename, bytes)
        publish()
        if drained {
            // Reset the counters so the next "bewaar dit album" starts from
            // 0 of n instead of continuing yesterday's total.
            lock.lock(); total = 0; completed = 0; failed = 0; lock.unlock()
        } else {
            startNextIfIdle()
        }
    }
}

// MARK: - URLSessionDownloadDelegate

extension OfflineDownloadManager: URLSessionDownloadDelegate {

    /// The temp file is deleted the moment this returns, so the move happens
    /// here, synchronously — no `Task {}`, no hop to another actor.
    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        lock.lock()
        let item = active?.item
        let variant = self.variant
        lock.unlock()
        // Fall back to the task description when the in-memory queue is gone —
        // a background session replays finished tasks into a relaunched process
        // that has no `active` any more.
        let key = item?.matchKey ?? downloadTask.taskDescription ?? ""
        guard !key.isEmpty else { return }

        // A 404/401 body is a perfectly successful *download* of an error page.
        // Without this check it would be pinned as the track's audio and play as
        // nothing — the failure would only surface on the plane.
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            if let item { finish(item, filename: nil, bytes: 0) }
            return
        }

        let bytes = (try? location.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        let filename = LocalAudioCache.storeDownload(movingFrom: location, forKey: key, variant: variant)
        guard let item else { return }   // replayed task with no queue: nothing to bookkeep here
        finish(item, filename: filename, bytes: filename == nil ? 0 : bytes)
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                           totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        lock.lock()
        currentFraction = fraction
        if let key = active?.item.matchKey { statuses[key] = .downloading(fraction: fraction) }
        lock.unlock()
        publish()
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Success is handled in `didFinishDownloadingTo`, which has already
        // cleared `active`; this only has to catch the error path.
        guard error != nil else { return }
        lock.lock()
        let item = active?.item
        lock.unlock()
        guard let item, item.matchKey == (task.taskDescription ?? item.matchKey) else { return }
        finish(item, filename: nil, bytes: 0)
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        let handler = backgroundCompletionHandler
        backgroundCompletionHandler = nil
        handler?()
    }
}
