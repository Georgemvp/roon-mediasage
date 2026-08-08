import Foundation

/// Outbound notifications.
///
/// The server knows things the user would want to hear about — a weekly playlist
/// finished building, a scheduled job started failing, the Roon core dropped —
/// and until now the only way to learn any of it was to open the app and look.
/// Lidarr's answer is a provider model: several transports, per-event triggers,
/// and a Test button per provider. That last detail is the one that matters in
/// practice: without it nobody ever configures a webhook correctly.
///
/// Deliberately small: two transports that need no account (a generic webhook and
/// ntfy) and one delivery rule. Adding a third transport means conforming to
/// `NotificationTransport`, nothing else.

/// What happened. Raw values are stable — they go over the wire in the payload
/// and users filter on them.
public enum NotificationEvent: String, Codable, Sendable, CaseIterable {
    case healthDegraded = "health.degraded"
    case taskFailed = "task.failed"
    case discoveryReady = "discovery.ready"
    case weeklyReady = "weekly.ready"
    case testMessage = "test"

    public var title: String {
        switch self {
        case .healthDegraded: return "RoonSage: aandacht nodig"
        case .taskFailed: return "RoonSage: taak mislukt"
        case .discoveryReady: return "RoonSage: nieuwe ontdekkingen"
        case .weeklyReady: return "RoonSage: Ontdek Wekelijks is klaar"
        case .testMessage: return "RoonSage: testbericht"
        }
    }

    /// Whether this event is worth waking someone for. ntfy maps it to a priority;
    /// the webhook passes it through so a receiving automation can branch on it.
    public var isUrgent: Bool {
        self == .healthDegraded || self == .taskFailed
    }
}

/// One configured destination.
public struct NotificationDestination: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable {
        /// POST the JSON payload verbatim to a URL.
        case webhook
        /// ntfy.sh (or a self-hosted instance): the URL is the topic endpoint.
        case ntfy
    }

    public var id: String
    public var kind: Kind
    public var url: String
    public var enabled: Bool
    /// Events this destination wants. Empty means all of them.
    public var events: [NotificationEvent]

    public init(id: String = UUID().uuidString, kind: Kind, url: String,
                enabled: Bool = true, events: [NotificationEvent] = []) {
        self.id = id
        self.kind = kind
        self.url = url
        self.enabled = enabled
        self.events = events
    }

    /// Whether this destination should receive `event`.
    public func wants(_ event: NotificationEvent) -> Bool {
        guard enabled else { return false }
        // A test must always go through, otherwise the Test button lies about a
        // destination that filters everything out.
        if event == .testMessage { return true }
        return events.isEmpty || events.contains(event)
    }
}

/// The wire format. One shape for every transport so a receiving automation can
/// branch on `event` without knowing which destination it came from.
public struct NotificationPayload: Codable, Sendable, Equatable {
    public let event: String
    public let title: String
    public let message: String
    public let urgent: Bool
    public let source: String

    public init(event: NotificationEvent, message: String) {
        self.event = event.rawValue
        self.title = event.title
        self.message = message
        self.urgent = event.isUrgent
        self.source = "roonsage"
    }
}

/// The HTTP side, behind a protocol so the delivery rules can be tested without
/// a network.
public protocol NotificationTransport: Sendable {
    /// Returns whether the destination accepted it.
    func send(_ payload: NotificationPayload, to destination: NotificationDestination) async -> Bool
}

public struct URLSessionNotificationTransport: NotificationTransport {
    public init() {}

    public func send(_ payload: NotificationPayload, to destination: NotificationDestination) async -> Bool {
        guard let url = URL(string: destination.url) else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 15

        switch destination.kind {
        case .webhook:
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONEncoder().encode(payload)
        case .ntfy:
            // ntfy takes a plain-text body plus headers for title and priority.
            req.setValue("text/plain", forHTTPHeaderField: "Content-Type")
            req.setValue(payload.title, forHTTPHeaderField: "Title")
            req.setValue(payload.urgent ? "high" : "default", forHTTPHeaderField: "Priority")
            req.httpBody = Data(payload.message.utf8)
        }

        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let code = (resp as? HTTPURLResponse)?.statusCode else { return false }
        return (200..<300).contains(code)
    }
}

public actor NotificationService {

    public static let shared = NotificationService()

    private static let storeKey = "notification_destinations"

    private var transport: NotificationTransport
    /// Suppression window per event, so a job failing every 15 minutes doesn't
    /// become 96 notifications a day. Distinct events are never suppressed by
    /// each other.
    static let repeatWindow: TimeInterval = 6 * 60 * 60
    private var lastSent: [NotificationEvent: Date] = [:]

    public init(transport: NotificationTransport = URLSessionNotificationTransport()) {
        self.transport = transport
    }

    public func setTransport(_ t: NotificationTransport) { transport = t }

    // MARK: - Configuration

    public func destinations() -> [NotificationDestination] {
        guard let data = UserDefaults.standard.data(forKey: Self.storeKey),
              let list = try? JSONDecoder().decode([NotificationDestination].self, from: data)
        else { return [] }
        return list
    }

    public func save(_ list: [NotificationDestination]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: Self.storeKey)
        }
    }

    public func upsert(_ destination: NotificationDestination) {
        var list = destinations()
        if let i = list.firstIndex(where: { $0.id == destination.id }) { list[i] = destination }
        else { list.append(destination) }
        save(list)
    }

    public func remove(id: String) {
        save(destinations().filter { $0.id != id })
    }

    // MARK: - Delivery

    /// Which destinations should get this event, and whether the repeat window
    /// allows it. Pure given the inputs, so the rules are testable.
    static func recipients(_ destinations: [NotificationDestination],
                           event: NotificationEvent,
                           lastSent: Date?,
                           now: Date) -> [NotificationDestination] {
        // A test is a deliberate user action and never suppressed.
        if event != .testMessage, let lastSent,
           now.timeIntervalSince(lastSent) < repeatWindow {
            return []
        }
        return destinations.filter { $0.wants(event) }
    }

    /// Fan out one event. Returns how many destinations accepted it.
    @discardableResult
    public func notify(_ event: NotificationEvent, message: String, now: Date = Date()) async -> Int {
        let targets = Self.recipients(destinations(), event: event,
                                      lastSent: lastSent[event], now: now)
        guard !targets.isEmpty else { return 0 }
        if event != .testMessage { lastSent[event] = now }

        let payload = NotificationPayload(event: event, message: message)
        var accepted = 0
        for destination in targets where await transport.send(payload, to: destination) {
            accepted += 1
        }
        if accepted < targets.count {
            Log.warning("notificatie ‘\(event.rawValue)’: \(accepted)/\(targets.count) bestemmingen accepteerden", category: .network)
        }
        return accepted
    }

    /// Send a test to one destination (or all when `id` is nil). This is what the
    /// Test button calls; it bypasses both the event filter and the repeat window.
    @discardableResult
    public func sendTest(to id: String? = nil) async -> Int {
        let all = destinations()
        let targets = id.map { wanted in all.filter { $0.id == wanted } } ?? all
        guard !targets.isEmpty else { return 0 }
        let payload = NotificationPayload(event: .testMessage,
                                          message: "Als je dit ziet, werkt de koppeling.")
        var accepted = 0
        for destination in targets where await transport.send(payload, to: destination) {
            accepted += 1
        }
        return accepted
    }
}
