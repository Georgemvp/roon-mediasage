import AudioAnalysis
import XCTest

final class ProviderGateTests: XCTestCase {

    func testConsecutiveFailuresTriggersCooldown() async {
        let gate = ProviderGate()
        await gate.configure(provider: "test-prov", config: .init(minInterval: 0, failureThreshold: 3, initialCooldown: 10, maxCooldown: 60))

        let t0 = Date(timeIntervalSince1970: 1000)
        await gate.recordFailure(for: "test-prov", error: "503", now: t0)
        let s1 = await gate.status(for: "test-prov", now: t0)
        XCTAssertEqual(s1.consecutiveFailures, 1)
        XCTAssertTrue(s1.isAvailable)

        await gate.recordFailure(for: "test-prov", error: "503", now: t0)
        let s2 = await gate.status(for: "test-prov", now: t0)
        XCTAssertEqual(s2.consecutiveFailures, 2)
        XCTAssertTrue(s2.isAvailable)

        // 3rd failure reaches threshold -> disabled for 10s
        await gate.recordFailure(for: "test-prov", error: "503", now: t0)
        let s3 = await gate.status(for: "test-prov", now: t0)
        XCTAssertEqual(s3.consecutiveFailures, 3)
        XCTAssertFalse(s3.isAvailable)
        XCTAssertEqual(s3.disabledUntil, Date(timeIntervalSince1970: 1010))

        // During cooldown, awaitSlot returns false immediately
        let allowedDuring = await gate.awaitSlot(for: "test-prov", now: Date(timeIntervalSince1970: 1005))
        XCTAssertFalse(allowedDuring)

        // After cooldown expires, awaitSlot returns true
        let allowedAfter = await gate.awaitSlot(for: "test-prov", now: Date(timeIntervalSince1970: 1011))
        XCTAssertTrue(allowedAfter)
    }

    func testSuccessResetsFailureCounter() async {
        let gate = ProviderGate()
        await gate.configure(provider: "mb", config: .init(minInterval: 0, failureThreshold: 3, initialCooldown: 10))

        let t0 = Date(timeIntervalSince1970: 1000)
        await gate.recordFailure(for: "mb", error: "timeout", now: t0)
        await gate.recordFailure(for: "mb", error: "timeout", now: t0)
        let s1 = await gate.status(for: "mb", now: t0)
        XCTAssertEqual(s1.consecutiveFailures, 2)

        await gate.recordSuccess(for: "mb")
        let s2 = await gate.status(for: "mb", now: t0)
        XCTAssertEqual(s2.consecutiveFailures, 0)
        XCTAssertNil(s2.disabledUntil)
        XCTAssertNil(s2.lastError)
        XCTAssertTrue(s2.isAvailable)
    }

    func testPacingEnforcesMinInterval() async {
        let gate = ProviderGate()
        await gate.configure(provider: "paced", config: .init(minInterval: 0.05))

        let start = Date()
        await gate.awaitSlot(for: "paced")
        await gate.awaitSlot(for: "paced")
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertGreaterThanOrEqual(elapsed, 0.04)
    }
}
