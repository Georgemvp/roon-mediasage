@testable import RoonSageCore
import XCTest

/// Covers the delivery rules: who gets an event, what the repeat window
/// suppresses, and that a test always goes through. A stub transport stands in
/// for the network, so these assert behaviour rather than connectivity.
final class NotificationServiceTests: XCTestCase {

    private actor StubTransport: NotificationTransport {
        private(set) var sent: [(NotificationPayload, NotificationDestination)] = []
        var accept = true

        func setAccept(_ v: Bool) { accept = v }
        func count() -> Int { sent.count }
        func payloads() -> [NotificationPayload] { sent.map(\.0) }

        func send(_ payload: NotificationPayload, to destination: NotificationDestination) async -> Bool {
            sent.append((payload, destination))
            return accept
        }
    }

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func webhook(events: [NotificationEvent] = [], enabled: Bool = true) -> NotificationDestination {
        NotificationDestination(id: "wh", kind: .webhook, url: "https://example.invalid/hook",
                                enabled: enabled, events: events)
    }

    // MARK: - Event filtering

    func testEmptyEventListMeansEverything() {
        let d = webhook()
        for event in NotificationEvent.allCases {
            XCTAssertTrue(d.wants(event), "\(event.rawValue) hoort geleverd te worden")
        }
    }

    func testExplicitEventListFilters() {
        let d = webhook(events: [.weeklyReady])
        XCTAssertTrue(d.wants(.weeklyReady))
        XCTAssertFalse(d.wants(.discoveryReady))
        XCTAssertFalse(d.wants(.healthDegraded))
    }

    func testDisabledDestinationGetsNothing() {
        let d = webhook(enabled: false)
        XCTAssertFalse(d.wants(.weeklyReady))
        XCTAssertFalse(d.wants(.testMessage))
    }

    /// A destination that filters everything must still receive a test, otherwise
    /// the Test button reports failure on a perfectly good configuration.
    func testTestMessageBypassesTheEventFilter() {
        XCTAssertTrue(webhook(events: [.weeklyReady]).wants(.testMessage))
    }

    // MARK: - Repeat window

    func testRepeatWindowSuppressesTheSameEvent() {
        let list = [webhook()]
        let first = NotificationService.recipients(list, event: .taskFailed, lastSent: nil, now: t0)
        XCTAssertEqual(first.count, 1)

        let tooSoon = NotificationService.recipients(
            list, event: .taskFailed, lastSent: t0, now: t0.addingTimeInterval(60))
        XCTAssertTrue(tooSoon.isEmpty, "een taak die elk kwartier faalt mag geen 96 berichten geven")

        let later = NotificationService.recipients(
            list, event: .taskFailed, lastSent: t0,
            now: t0.addingTimeInterval(NotificationService.repeatWindow + 1))
        XCTAssertEqual(later.count, 1)
    }

    func testDistinctEventsDoNotSuppressEachOther() {
        let list = [webhook()]
        // healthDegraded's own history is nil even though taskFailed just fired.
        let r = NotificationService.recipients(list, event: .healthDegraded, lastSent: nil, now: t0)
        XCTAssertEqual(r.count, 1)
    }

    func testTestMessageIsNeverSuppressed() {
        let r = NotificationService.recipients([webhook()], event: .testMessage,
                                               lastSent: t0, now: t0.addingTimeInterval(1))
        XCTAssertEqual(r.count, 1)
    }

    // MARK: - Payload

    func testPayloadCarriesEventAndUrgency() {
        let urgent = NotificationPayload(event: .taskFailed, message: "feature-sync stuk")
        XCTAssertEqual(urgent.event, "task.failed")
        XCTAssertTrue(urgent.urgent)
        XCTAssertEqual(urgent.source, "roonsage")
        XCTAssertEqual(urgent.message, "feature-sync stuk")

        let calm = NotificationPayload(event: .weeklyReady, message: "klaar")
        XCTAssertFalse(calm.urgent, "een klare playlist hoeft niemand te wekken")
    }

    func testEventRawValuesAreStable() {
        // Users filter automations on these strings; renaming one silently breaks
        // every receiving integration.
        XCTAssertEqual(NotificationEvent.healthDegraded.rawValue, "health.degraded")
        XCTAssertEqual(NotificationEvent.taskFailed.rawValue, "task.failed")
        XCTAssertEqual(NotificationEvent.discoveryReady.rawValue, "discovery.ready")
        XCTAssertEqual(NotificationEvent.weeklyReady.rawValue, "weekly.ready")
        XCTAssertEqual(NotificationEvent.testMessage.rawValue, "test")
    }

    // MARK: - Fan-out through a transport

    func testNotifyDeliversToEveryWantingDestination() async {
        let stub = StubTransport()
        let service = NotificationService(transport: stub)
        await service.save([
            NotificationDestination(id: "a", kind: .webhook, url: "https://a.invalid"),
            NotificationDestination(id: "b", kind: .ntfy, url: "https://b.invalid/topic"),
            NotificationDestination(id: "c", kind: .webhook, url: "https://c.invalid",
                                    enabled: false),
        ])
        defer { Task { await service.save([]) } }

        let accepted = await service.notify(.weeklyReady, message: "klaar", now: t0)
        XCTAssertEqual(accepted, 2, "de uitgeschakelde bestemming telt niet mee")
        let count = await stub.count()
        XCTAssertEqual(count, 2)
    }

    func testRejectedDeliveryIsCountedNotSwallowed() async {
        let stub = StubTransport()
        await stub.setAccept(false)
        let service = NotificationService(transport: stub)
        await service.save([NotificationDestination(id: "a", kind: .webhook, url: "https://a.invalid")])
        defer { Task { await service.save([]) } }

        let accepted = await service.notify(.taskFailed, message: "stuk", now: t0)
        XCTAssertEqual(accepted, 0, "een geweigerde levering mag niet als succes tellen")
        let attempts = await stub.count()
        XCTAssertEqual(attempts, 1, "hij moet het wel geprobeerd hebben")
    }

    func testUpsertReplacesRatherThanDuplicates() async {
        let service = NotificationService(transport: StubTransport())
        defer { Task { await service.save([]) } }
        await service.save([])

        var d = NotificationDestination(id: "x", kind: .webhook, url: "https://one.invalid")
        await service.upsert(d)
        d.url = "https://two.invalid"
        await service.upsert(d)

        let list = await service.destinations()
        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list.first?.url, "https://two.invalid")
    }
}
