@testable import RoonSageCore
import XCTest

/// Covers the scheduler's contract: a job runs on its cadence, a manual trigger
/// is deduped while one is in flight, a job can steer its own next interval, and
/// a failure is recorded rather than swallowed.
///
/// Intervals here are milliseconds so the suite stays fast; the scheduler has no
/// minimum cadence.
final class TaskSchedulerTests: XCTestCase {

    /// Counts invocations across concurrency domains.
    private actor Counter {
        private(set) var value = 0
        func bump() -> Int { value += 1; return value }
        func get() -> Int { value }
    }

    private func waitUntil(_ timeout: TimeInterval = 3,
                           _ condition: @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return await condition()
    }

    func testJobRunsRepeatedlyOnItsInterval() async {
        let scheduler = TaskScheduler()
        let counter = Counter()

        await scheduler.register(name: "tick", title: "Tick", interval: 0.02) {
            _ = await counter.bump()
            return .completed
        }
        defer { Task { await scheduler.stopAll() } }

        let ran = await waitUntil { await counter.get() >= 3 }
        XCTAssertTrue(ran, "job moet herhaald draaien op zijn interval")
    }

    func testInitialDelayIsRespectedForANeverRunJob() async {
        let scheduler = TaskScheduler()
        let counter = Counter()

        await scheduler.register(name: "later", title: "Later", interval: 0.01, initialDelay: 5) {
            _ = await counter.bump()
            return .completed
        }
        defer { Task { await scheduler.stopAll() } }

        try? await Task.sleep(nanoseconds: 150_000_000)
        let count = await counter.get()
        XCTAssertEqual(count, 0, "een startgrace moet de eerste run uitstellen")
    }

    /// The other half of the startup grace, and the one that was missing: after
    /// the delay has elapsed the job must ACTUALLY run.
    ///
    /// Its absence hid a real defect for a full release cycle. `nextDue` returned
    /// `Date() + initialDelay` — recomputed on every check — so a job that had
    /// never run could never become due: it slept the grace, woke, asked again,
    /// got a fresh future date, and slept again. On the live server that silently
    /// disabled the artist-radio sync, discovery run, digest, weekly and feature
    /// sync for hours, while /system/tasks calmly reported "never".
    ///
    /// The old test only asserted the job does NOT run early, which passes just as
    /// happily when it never runs at all.
    func testJobRunsOnceTheInitialDelayHasElapsed() async {
        let scheduler = TaskScheduler()
        let counter = Counter()

        await scheduler.register(name: "delayed", title: "Delayed",
                                 interval: 3600, initialDelay: 0.05) {
            _ = await counter.bump()
            return .completed
        }
        defer { Task { await scheduler.stopAll() } }

        let ran = await waitUntil(2) { await counter.get() >= 1 }
        XCTAssertTrue(ran, "na de startgrace hoort de taak te draaien, niet eeuwig te blijven wachten")
    }

    /// And a never-run job must report a due date that stands still, rather than
    /// receding every time it is consulted.
    func testNeverRunJobsDueDateDoesNotRecede() async {
        let scheduler = TaskScheduler()
        await scheduler.register(name: "anchored", title: "Anchored",
                                 interval: 3600, initialDelay: 60) { .completed }
        defer { Task { await scheduler.stopAll() } }

        let first = await scheduler.info().first { $0.name == "anchored" }?.nextExecution
        try? await Task.sleep(nanoseconds: 120_000_000)
        let second = await scheduler.info().first { $0.name == "anchored" }?.nextExecution
        XCTAssertEqual(first, second, "de startgrace moet aan de registratie hangen, niet aan nu")
        XCTAssertNotNil(first, "een nog niet gedraaide taak hoort een vaste verwachte tijd te melden")
    }

    func testRunNowIsDedupedWhileInFlight() async {
        let scheduler = TaskScheduler()
        let counter = Counter()

        await scheduler.register(name: "slow", title: "Slow", interval: 3600, initialDelay: 3600) {
            _ = await counter.bump()
            try? await Task.sleep(nanoseconds: 300_000_000)
            return .completed
        }
        defer { Task { await scheduler.stopAll() } }

        let first = await scheduler.runNow("slow")
        XCTAssertTrue(first, "de eerste handmatige trigger moet worden geaccepteerd")

        // Give the run a moment to actually start before the second attempt.
        _ = await waitUntil { await scheduler.isRunning("slow") }
        let second = await scheduler.runNow("slow")
        XCTAssertFalse(second, "een tweede trigger tijdens de vlucht moet geweigerd worden")

        // Note: `&&` takes its right operand as an @autoclosure, which cannot
        // carry an `await` — so the two conditions are evaluated separately.
        let done = await waitUntil {
            let ran = await counter.get() == 1
            let idle = await !scheduler.isRunning("slow")
            return ran && idle
        }
        XCTAssertTrue(done)
        let total = await counter.get()
        XCTAssertEqual(total, 1, "gededupliceerd betekent één uitvoering, niet twee")
    }

    func testRunNowOnUnknownJobIsRejected() async {
        let scheduler = TaskScheduler()
        let accepted = await scheduler.runNow("bestaat-niet")
        XCTAssertFalse(accepted)
    }

    func testOutcomeCanSteerTheNextInterval() async {
        let scheduler = TaskScheduler()
        let counter = Counter()

        await scheduler.register(name: "adaptive", title: "Adaptive", interval: 0.01) {
            let n = await counter.bump()
            // First run asks for a very long next interval; a second run would
            // therefore mean the override was ignored.
            return n == 1 ? .retry(after: 3600) : .completed
        }
        defer { Task { await scheduler.stopAll() } }

        _ = await waitUntil { await counter.get() >= 1 }
        try? await Task.sleep(nanoseconds: 200_000_000)
        let total = await counter.get()
        XCTAssertEqual(total, 1, "nextInterval moet de geregistreerde cadans vervangen")
    }

    func testFailureIsRecordedNotSwallowed() async {
        let scheduler = TaskScheduler()

        await scheduler.register(name: "broken", title: "Broken", interval: 3600, initialDelay: 3600) {
            .failed("kapot")
        }
        defer { Task { await scheduler.stopAll() } }

        let accepted = await scheduler.runNow("broken")
        XCTAssertTrue(accepted)
        let recorded = await waitUntil {
            let info = await scheduler.info().first { $0.name == "broken" }
            return info?.lastStatus == "failed"
        }
        XCTAssertTrue(recorded)

        let info = await scheduler.info().first { $0.name == "broken" }
        XCTAssertEqual(info?.lastError, "kapot")
        XCTAssertEqual(info?.failureCount, 1)
        XCTAssertEqual(info?.runCount, 1)
        XCTAssertNotNil(info?.lastExecution)
    }

    func testRegisteringTheSameNameTwiceIsANoOp() async {
        let scheduler = TaskScheduler()
        let counter = Counter()

        await scheduler.register(name: "once", title: "Once", interval: 3600, initialDelay: 3600) {
            _ = await counter.bump(); return .completed
        }
        await scheduler.register(name: "once", title: "Duplicaat", interval: 3600, initialDelay: 3600) {
            _ = await counter.bump(); return .completed
        }
        defer { Task { await scheduler.stopAll() } }

        let all = await scheduler.info()
        XCTAssertEqual(all.filter { $0.name == "once" }.count, 1)
        XCTAssertEqual(all.first { $0.name == "once" }?.title, "Once",
                       "de eerste registratie wint; de tweede is een no-op")
    }

    func testInfoReportsNeverRunJobs() async {
        let scheduler = TaskScheduler()
        await scheduler.register(name: "idle", title: "Idle", interval: 3600, initialDelay: 3600) { .completed }
        defer { Task { await scheduler.stopAll() } }

        let info = await scheduler.info().first { $0.name == "idle" }
        XCTAssertEqual(info?.lastStatus, "never")
        XCTAssertNil(info?.lastExecution)
        // Was: nil. A never-run job now reports its anchored first run, so the UI
        // can distinguish "hasn't run yet" from "will never run" — the exact
        // ambiguity that hid the stuck-scheduler bug.
        XCTAssertNotNil(info?.nextExecution)
        XCTAssertEqual(info?.runCount, 0)
        XCTAssertFalse(info?.isRunning ?? true)
    }
}
