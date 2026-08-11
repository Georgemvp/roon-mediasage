import Foundation
import Network

/// Client-side policy for requesting AAC transcoding on the `/audio` stream
/// (LMS-audit §1.2): full-quality FLAC on the home network, a bandwidth-
/// friendly AAC when listening over ZeroTier on cellular.
public enum LocalTranscode {
    public enum Mode: String, CaseIterable, Sendable {
        case off        // always the original file
        case cellular   // transcode only on an expensive path (mobile data / hotspot)
        case always
    }

    static let modeKey = "local_transcode_mode"
    static let bitrateKey = "local_transcode_kbps"

    /// Default `.cellular`: on a phone, streaming full FLAC over mobile data is
    /// the single biggest way to burn a bundle, and nobody opts in to a setting
    /// they don't know exists. At home nothing changes — the policy only fires on
    /// an expensive path. An explicit choice is always honoured; only "never set"
    /// gets the default.
    public static var mode: Mode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: modeKey) else { return .cellular }
            return Mode(rawValue: raw) ?? .cellular
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    /// Requested AAC bitrate in kbps (default 256).
    public static var bitrateKbps: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: bitrateKey)
            return v > 0 ? v : 256
        }
        set { UserDefaults.standard.set(newValue, forKey: bitrateKey) }
    }

    /// Query items to append to an `/audio` URL, or empty when the policy says
    /// to stream the original.
    public static func queryItems() -> [URLQueryItem] {
        let active: Bool = switch mode {
        case .off: false
        case .always: true
        case .cellular: NetworkPathMonitor.shared.isExpensive
        }
        guard active else { return [] }
        return [URLQueryItem(name: "format", value: "aac"),
                URLQueryItem(name: "bitrate", value: String(bitrateKbps))]
    }
}

/// Tiny always-on NWPathMonitor wrapper — `isExpensive` mirrors whether the
/// current default path is cellular / a personal hotspot.
public final class NetworkPathMonitor: @unchecked Sendable {
    public static let shared = NetworkPathMonitor()
    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var _isExpensive = false

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            lock.lock(); _isExpensive = path.isExpensive; lock.unlock()
        }
        monitor.start(queue: DispatchQueue(label: "roonsage.pathmonitor"))
    }

    public var isExpensive: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isExpensive
    }
}
