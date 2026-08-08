@testable import RoonSageCore
import XCTest

/// The thresholds are the whole point of a health check — a check that says "ok"
/// at 200 MB free is worse than no check. Every decision here is a pure function,
/// so the boundaries are asserted directly.
final class HealthCheckTests: XCTestCase {

    private let gb: Int64 = 1_073_741_824

    // MARK: - Disk

    func testDiskLevelsAtTheirBoundaries() {
        XCTAssertEqual(HealthChecks.diskSpace(freeBytes: 20 * gb).level, .ok)
        XCTAssertEqual(HealthChecks.diskSpace(freeBytes: 5 * gb).level, .ok)
        XCTAssertEqual(HealthChecks.diskSpace(freeBytes: 5 * gb - 1).level, .warning)
        XCTAssertEqual(HealthChecks.diskSpace(freeBytes: gb).level, .warning)
        XCTAssertEqual(HealthChecks.diskSpace(freeBytes: gb - 1).level, .error)
        XCTAssertEqual(HealthChecks.diskSpace(freeBytes: 0).level, .error)
    }

    func testDiskErrorCarriesAnActionableHint() {
        XCTAssertNotNil(HealthChecks.diskSpace(freeBytes: 100).hint)
        XCTAssertNil(HealthChecks.diskSpace(freeBytes: 100 * gb).hint,
                     "een gezonde uitkomst hoort geen advies te geven")
    }

    // MARK: - Sync age

    func testSyncAgeLevels() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func age(_ days: Double) -> HealthResult.Level {
            HealthChecks.syncAge(lastSync: now.addingTimeInterval(-days * 86_400), now: now).level
        }
        XCTAssertEqual(age(0), .ok)
        XCTAssertEqual(age(7), .ok)
        XCTAssertEqual(age(8), .warning)
        XCTAssertEqual(age(30), .warning)
        XCTAssertEqual(age(31), .error)
    }

    func testNeverSyncedIsAWarningNotAnError() {
        // Nothing is broken on a fresh install — it just hasn't run yet.
        let r = HealthChecks.syncAge(lastSync: nil)
        XCTAssertEqual(r.level, .warning)
        XCTAssertNotNil(r.hint)
    }

    // MARK: - Feature coverage

    func testFeatureCoverageLevels() {
        XCTAssertEqual(HealthChecks.featureCoverage(features: 900, tracks: 1000).level, .ok)
        XCTAssertEqual(HealthChecks.featureCoverage(features: 600, tracks: 1000).level, .ok)
        XCTAssertEqual(HealthChecks.featureCoverage(features: 599, tracks: 1000).level, .warning)
        XCTAssertEqual(HealthChecks.featureCoverage(features: 250, tracks: 1000).level, .warning)
        XCTAssertEqual(HealthChecks.featureCoverage(features: 249, tracks: 1000).level, .error)
    }

    /// An empty library is not a broken one — a fresh client must not open on red.
    func testEmptyLibraryIsNotAFailure() {
        let r = HealthChecks.featureCoverage(features: 0, tracks: 0)
        XCTAssertEqual(r.level, .ok)
    }

    // MARK: - Scheduled tasks

    func testFailingTaskIsReportedByName() {
        let tasks = [
            DatabaseManager.ScheduledTaskRecord(name: "discovery-run", lastStatus: "completed"),
            DatabaseManager.ScheduledTaskRecord(name: "feature-sync", lastStatus: "failed",
                                                lastError: "analyzer onbereikbaar"),
        ]
        let r = HealthChecks.scheduledTasks(tasks)
        XCTAssertEqual(r.level, .error)
        XCTAssertTrue(r.message.contains("feature-sync"))
        XCTAssertFalse(r.message.contains("discovery-run"), "gezonde taken horen er niet bij te staan")
        XCTAssertEqual(r.hint, "analyzer onbereikbaar")
    }

    func testAllHealthyTasksAreOk() {
        let tasks = [DatabaseManager.ScheduledTaskRecord(name: "a", lastStatus: "completed")]
        XCTAssertEqual(HealthChecks.scheduledTasks(tasks).level, .ok)
        XCTAssertEqual(HealthChecks.scheduledTasks([]).level, .ok)
    }

    // MARK: - Devices, discovery, Roon

    func testPendingDevicesWarnOnlyWhenThereAreAny() {
        XCTAssertEqual(HealthChecks.pendingDevices(count: 0).level, .ok)
        XCTAssertEqual(HealthChecks.pendingDevices(count: 1).level, .warning)
    }

    func testDegradedDiscoveryWarnsAndUnknownDoesNot() {
        XCTAssertEqual(HealthChecks.discoveryHealth(lastBatchDegraded: true).level, .warning)
        XCTAssertEqual(HealthChecks.discoveryHealth(lastBatchDegraded: false).level, .ok)
        XCTAssertEqual(HealthChecks.discoveryHealth(lastBatchDegraded: nil).level, .ok)
    }

    func testDisconnectedRoonIsAnError() {
        XCTAssertEqual(HealthChecks.roonConnection(isConnected: false, coreName: nil).level, .error)
        let ok = HealthChecks.roonConnection(isConnected: true, coreName: "Mac mini")
        XCTAssertEqual(ok.level, .ok)
        XCTAssertTrue(ok.message.contains("Mac mini"))
    }

    // MARK: - Level ordering

    func testLevelsOrderSoTheWorstWins() {
        XCTAssertLessThan(HealthResult.Level.ok, .warning)
        XCTAssertLessThan(HealthResult.Level.warning, .error)
        XCTAssertEqual([HealthResult.Level.ok, .error, .warning].max(), .error)
    }

    // MARK: - Service

    func testServiceRunsEveryCheckAndSortsWorstFirst() async {
        let service = HealthCheckService()
        await service.register(id: "a", title: "A") {
            .init(checkID: "a", title: "A", level: .ok, message: "prima")
        }
        await service.register(id: "b", title: "B") {
            .init(checkID: "b", title: "B", level: .error, message: "stuk")
        }
        await service.register(id: "c", title: "C") {
            .init(checkID: "c", title: "C", level: .warning, message: "let op")
        }

        let results = await service.results()
        XCTAssertEqual(results.count, 3)
        XCTAssertEqual(results.map(\.level), [.error, .warning, .ok],
                       "het ergste hoort bovenaan, niet begraven")
        let worst = await service.worstLevel()
        XCTAssertEqual(worst, .error)
    }

    func testResultsAreCachedWithinTheWindow() async {
        let service = HealthCheckService()
        let counter = Counter()
        await service.register(id: "a", title: "A") {
            await counter.bump()
            return .init(checkID: "a", title: "A", level: .ok, message: "")
        }

        let t = Date(timeIntervalSince1970: 1_800_000_000)
        _ = await service.results(now: t)
        _ = await service.results(now: t.addingTimeInterval(5))
        var runs = await counter.get()
        XCTAssertEqual(runs, 1, "binnen het venster hoort de cache te gelden")

        _ = await service.results(now: t.addingTimeInterval(HealthCheckService.cacheWindow + 1))
        runs = await counter.get()
        XCTAssertEqual(runs, 2, "daarbuiten hoort hij opnieuw te meten")
    }

    func testRegisteringANewCheckInvalidatesTheCache() async {
        let service = HealthCheckService()
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        await service.register(id: "a", title: "A") {
            .init(checkID: "a", title: "A", level: .ok, message: "")
        }
        _ = await service.results(now: t)
        await service.register(id: "b", title: "B") {
            .init(checkID: "b", title: "B", level: .error, message: "")
        }
        let results = await service.results(now: t.addingTimeInterval(1))
        XCTAssertEqual(results.count, 2, "een verse check mag niet achter de cache blijven hangen")
    }

    private actor Counter {
        private(set) var value = 0
        func bump() { value += 1 }
        func get() -> Int { value }
    }
}
