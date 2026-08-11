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

    /// The defaults as constants, because the settings screen binds `@AppStorage`
    /// to the SAME keys this type reads. When the two disagree the screen lies
    /// about what the app is doing — and it did: the picker defaulted to "Nooit"
    /// while the policy was already transcoding on cellular. One source, no drift.
    public static let defaultMode: Mode = .cellular

    /// 96 kbps, which is below `AudioTranscoder.heAACCeiling` — so the default
    /// cellular stream is HE-AAC, not LC. HE holds together at a bitrate where
    /// LC audibly falls apart, and this is the whole point of the setting:
    /// ~43 MB/hour instead of ~400 MB/hour of FLAC. Picking 192 or 256 opts back
    /// into LC at a quality the higher bitrate can carry.
    public static let defaultBitrateKbps = 96

    /// Default `.cellular`: on a phone, streaming full FLAC over mobile data is
    /// the single biggest way to burn a bundle, and nobody opts in to a setting
    /// they don't know exists. At home nothing changes — the policy only fires on
    /// an expensive path. An explicit choice is always honoured; only "never set"
    /// gets the default.
    public static var mode: Mode {
        get {
            guard let raw = UserDefaults.standard.string(forKey: modeKey) else { return defaultMode }
            return Mode(rawValue: raw) ?? defaultMode
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: modeKey) }
    }

    /// Requested AAC bitrate in kbps.
    public static var bitrateKbps: Int {
        get {
            let v = UserDefaults.standard.integer(forKey: bitrateKey)
            return v > 0 ? v : defaultBitrateKbps
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
