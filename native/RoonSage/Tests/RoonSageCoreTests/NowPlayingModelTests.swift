@testable import RoonSageCore
import XCTest

/// Covers the arithmetic the two former Now Playing screens each carried their
/// own copy of. Every case here is one that produced a visible wrong number at
/// some point: a bar that divided by a zero length, a paused clock that kept
/// running, a remaining time that went negative at a track boundary, and a NaN
/// duration from an AVAsset that hadn't finished loading.
final class NowPlayingModelTests: XCTestCase {

    // MARK: - Loop cycling

    func testLoopCyclesOffAllOneOff() {
        XCTAssertEqual(NowPlayingModel.nextLoop("disabled"), "loop")
        XCTAssertEqual(NowPlayingModel.nextLoop("loop"), "loop_one")
        XCTAssertEqual(NowPlayingModel.nextLoop("loop_one"), "disabled")
    }

    /// Roon has been seen to report modes we don't know; anything unrecognised
    /// must land on "off" so the next tap is predictable instead of stuck.
    func testUnknownLoopModeFallsBackToOff() {
        XCTAssertEqual(NowPlayingModel.nextLoop("shuffle_all"), "disabled")
        XCTAssertEqual(NowPlayingModel.nextLoop(""), "disabled")
    }

    // MARK: - Fraction

    func testFractionIsPositionOverDuration() {
        XCTAssertEqual(NowPlayingModel.fraction(position: 30, duration: 120), 0.25, accuracy: 0.0001)
    }

    /// A stream with no reported length must not divide by zero.
    func testFractionWithoutDurationIsZero() {
        XCTAssertEqual(NowPlayingModel.fraction(position: 42, duration: 0), 0)
    }

    func testFractionClampsBothEnds() {
        XCTAssertEqual(NowPlayingModel.fraction(position: -5, duration: 120), 0)
        XCTAssertEqual(NowPlayingModel.fraction(position: 500, duration: 120), 1)
    }

    func testFractionSurvivesNaN() {
        XCTAssertEqual(NowPlayingModel.fraction(position: .nan, duration: 120), 0)
        XCTAssertEqual(NowPlayingModel.fraction(position: 10, duration: .nan), 0)
    }

    // MARK: - Interpolated position

    func testPositionAdvancesWithWallClockWhilePlaying() {
        let anchoredAt = Date(timeIntervalSince1970: 1_000)
        let now = anchoredAt.addingTimeInterval(2.5)
        XCTAssertEqual(
            NowPlayingModel.interpolatedPosition(anchor: 10, anchoredAt: anchoredAt, now: now,
                                                 isPlaying: true, duration: 300),
            12.5, accuracy: 0.0001
        )
    }

    /// The bug this pins: while paused the elapsed interval must NOT accumulate,
    /// or resuming jumps forward by however long you sat on pause.
    func testPositionIsFrozenWhilePaused() {
        let anchoredAt = Date(timeIntervalSince1970: 1_000)
        let now = anchoredAt.addingTimeInterval(600)
        XCTAssertEqual(
            NowPlayingModel.interpolatedPosition(anchor: 10, anchoredAt: anchoredAt, now: now,
                                                 isPlaying: false, duration: 300),
            10, accuracy: 0.0001
        )
    }

    func testPositionNeverPassesTheEndOfTheTrack() {
        let anchoredAt = Date(timeIntervalSince1970: 1_000)
        let now = anchoredAt.addingTimeInterval(9_999)
        XCTAssertEqual(
            NowPlayingModel.interpolatedPosition(anchor: 290, anchoredAt: anchoredAt, now: now,
                                                 isPlaying: true, duration: 300),
            300, accuracy: 0.0001
        )
    }

    /// Without a known length there is nothing to clamp to, but the counter
    /// should still run — a frozen 0:00 on a live stream reads as broken.
    func testPositionKeepsRunningWithoutADuration() {
        let anchoredAt = Date(timeIntervalSince1970: 1_000)
        let now = anchoredAt.addingTimeInterval(30)
        XCTAssertEqual(
            NowPlayingModel.interpolatedPosition(anchor: 5, anchoredAt: anchoredAt, now: now,
                                                 isPlaying: true, duration: 0),
            35, accuracy: 0.0001
        )
    }

    /// A poll that arrives with a stamp in the future (clock skew between the
    /// Core and this device) must not wind the counter backwards.
    func testPositionIgnoresANegativeElapsedInterval() {
        let anchoredAt = Date(timeIntervalSince1970: 1_000)
        let now = anchoredAt.addingTimeInterval(-30)
        XCTAssertEqual(
            NowPlayingModel.interpolatedPosition(anchor: 10, anchoredAt: anchoredAt, now: now,
                                                 isPlaying: true, duration: 300),
            10, accuracy: 0.0001
        )
    }

    // MARK: - Seeking

    func testSeekMapsTheDragToSeconds() {
        XCTAssertEqual(NowPlayingModel.seekSeconds(atX: 100, width: 200, duration: 240)!,
                       120, accuracy: 0.0001)
    }

    func testSeekClampsOutsideTheBar() {
        XCTAssertEqual(NowPlayingModel.seekSeconds(atX: -40, width: 200, duration: 240)!, 0)
        XCTAssertEqual(NowPlayingModel.seekSeconds(atX: 900, width: 200, duration: 240)!, 240)
    }

    /// Nil, not 0: a drag on a zero-length stream must leave the position alone
    /// rather than yank it to the start.
    func testSeekIsNilWithoutSomethingToSeekWithin() {
        XCTAssertNil(NowPlayingModel.seekSeconds(atX: 100, width: 200, duration: 0))
        XCTAssertNil(NowPlayingModel.seekSeconds(atX: 100, width: 0, duration: 240))
    }

    // MARK: - Remaining

    func testRemainingCountsDown() {
        XCTAssertEqual(NowPlayingModel.remaining(position: 90, duration: 240), 150, accuracy: 0.0001)
    }

    /// At a track boundary Roon briefly reports a position past the length.
    func testRemainingNeverGoesNegative() {
        XCTAssertEqual(NowPlayingModel.remaining(position: 260, duration: 240), 0)
    }

    // MARK: - Formatting

    func testFormatsMinutesAndSeconds() {
        XCTAssertEqual(NowPlayingModel.formatTime(0), "0:00")
        XCTAssertEqual(NowPlayingModel.formatTime(9), "0:09")
        XCTAssertEqual(NowPlayingModel.formatTime(69), "1:09")
        XCTAssertEqual(NowPlayingModel.formatTime(599), "9:59")
    }

    /// Classical and DJ sets go past the hour; `%d:%02d` alone printed "83:20".
    func testFormatsPastTheHour() {
        XCTAssertEqual(NowPlayingModel.formatTime(3_600), "1:00:00")
        XCTAssertEqual(NowPlayingModel.formatTime(5_000), "1:23:20")
    }

    func testFormatSurvivesNaNAndNegatives() {
        XCTAssertEqual(NowPlayingModel.formatTime(.nan), "0:00")
        XCTAssertEqual(NowPlayingModel.formatTime(.infinity), "0:00")
        XCTAssertEqual(NowPlayingModel.formatTime(-12), "0:00")
    }

    func testRemainingLabelIsUnknownWithoutADuration() {
        XCTAssertEqual(NowPlayingModel.remainingLabel(position: 30, duration: 0), "--:--")
        XCTAssertEqual(NowPlayingModel.remainingLabel(position: 30, duration: 240), "-3:30")
    }
}
