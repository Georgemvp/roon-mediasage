import AVFoundation
import Foundation
import Network

/// Client-side policy for requesting transcoding on the `/audio` stream
/// (LMS-audit §1.2): full-quality FLAC on the home network, a bandwidth-
/// friendly AAC or Opus when listening over ZeroTier on cellular.
public enum LocalTranscode {
    public enum Mode: String, CaseIterable, Sendable {
        case off        // always the original file
        case cellular   // transcode only on an expensive path (mobile data / hotspot)
        case always
    }

    /// Which codec to ask the analyser for.
    ///
    /// Opus is the better codec at every bitrate this setting offers — but
    /// unlike AAC it is not guaranteed to be decodable, so it is only ever
    /// requested when `opusSupported` says this OS can actually play it.
    public enum Format: String, CaseIterable, Sendable {
        case aac
        case opus
    }

    static let modeKey = "local_transcode_mode"
    static let bitrateKey = "local_transcode_kbps"
    public static let formatKey = "local_transcode_format"

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

    /// AAC by default, because it is the only codec every Apple client is
    /// guaranteed to decode. Opus is an explicit, checked opt-in.
    public static let defaultFormat: Format = .aac

    /// Whether AVFoundation on THIS OS can decode Ogg/Opus.
    ///
    /// Measured, not assumed. `isPlayableExtendedMIMEType` has existed since
    /// iOS 5 / macOS 10.7, so the question can be asked on every OS this app
    /// supports — and it has to be asked, because Ogg container support arrived
    /// far later than the deployment floor (iOS 17 / macOS 14) and this project
    /// cannot test a device that old. Answering it at runtime means an OS that
    /// lacks it simply never sees the option, instead of silently playing
    /// nothing the first time the user leaves the house.
    ///
    /// Computed once: the answer cannot change while the process runs.
    public static let opusSupported: Bool =
        AVURLAsset.isPlayableExtendedMIMEType("audio/ogg; codecs=\"opus\"")

    /// The requested codec. An explicit choice is honoured; a stored `opus` on
    /// an OS that cannot decode it degrades to AAC rather than to silence —
    /// settings sync between devices, and the iPhone and the Mac need not agree
    /// about what they can play.
    public static var format: Format {
        get {
            let stored = UserDefaults.standard.string(forKey: formatKey)
                .flatMap(Format.init(rawValue:)) ?? defaultFormat
            return (stored == .opus && !opusSupported) ? .aac : stored
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: formatKey) }
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
        return [URLQueryItem(name: "format", value: format.rawValue),
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
