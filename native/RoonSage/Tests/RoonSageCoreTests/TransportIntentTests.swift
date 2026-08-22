import XCTest
@testable import RoonSageCore

/// Optimistic transport: the tap shows up before the server confirms.
///
/// Cover for the gap `TransportIntent` closes. Transport commands used to send
/// and wait for the next authoritative snapshot — the round-trip plus a poll
/// while playing, and up to fifteen seconds while PAUSED, because
/// `PlaybackEventHub` only pushes on a changed digest and a paused zone's digest
/// doesn't change. So play/pause looked dead, and a second tap undid the first.
final class TransportIntentTests: XCTestCase {

    private func zone(
        id: String = "z1", state: PlaybackState = .playing,
        shuffle: Bool? = false, loop: String? = "disabled",
        volume: Int? = 40, muted: Bool = false, outputID: String = "o1"
    ) -> Zone {
        var dict: [String: Any] = [
            "zone_id": id, "display_name": "Keuken", "state": state.rawValue,
            "settings": ["shuffle": shuffle as Any, "loop": loop as Any],
        ]
        if let volume {
            dict["outputs"] = [[
                "output_id": outputID, "zone_id": id, "display_name": "Keuken",
                "volume": ["value": volume, "min": 0, "max": 100, "step": 2,
                           "is_muted": muted, "type": "number"],
            ]]
        } else {
            dict["outputs"] = [["output_id": outputID, "zone_id": id, "display_name": "Keuken"]]
        }
        return Zone(from: dict)
    }

    // MARK: play / pause

    func testTogglePlayPauseFlipsBothWays() {
        let playing = [zone(state: .playing)]
        XCTAssertEqual(TransportIntent.togglePlayPause.applied(to: playing, zoneID: "z1")[0].state, .paused)

        let paused = [zone(state: .paused)]
        XCTAssertEqual(TransportIntent.togglePlayPause.applied(to: paused, zoneID: "z1")[0].state, .playing)
    }

    func testTogglePlayPauseLeavesUnsettledStatesAlone() {
        // `.loading` is Roon mid-transition and `.stopped` has nothing to resume.
        // Guessing there would be a worse lie than the delay this replaces.
        for state in [PlaybackState.loading, .stopped] {
            let zones = [zone(state: state)]
            XCTAssertEqual(TransportIntent.togglePlayPause.applied(to: zones, zoneID: "z1")[0].state, state,
                           "\(state) mag niet geraden worden")
        }
    }

    // MARK: shuffle / repeat

    func testSetShuffleAndLoop() {
        let zones = [zone(shuffle: false, loop: "disabled")]
        XCTAssertEqual(TransportIntent.setShuffle(true).applied(to: zones, zoneID: "z1")[0].shuffle, true)
        XCTAssertEqual(TransportIntent.setLoop("loop_one").applied(to: zones, zoneID: "z1")[0].loopMode, "loop_one")
    }

    // MARK: volume / mute

    func testSetVolumeClampsToTheOutputRange() {
        let zones = [zone(volume: 40)]
        // Well inside the range: taken as-is.
        XCTAssertEqual(TransportIntent.setVolume(52, outputID: "o1")
            .applied(to: zones, zoneID: "z1")[0].outputs[0].volume?.value, 52)
        // Past either end: show the end, not a number the server will contradict.
        XCTAssertEqual(TransportIntent.setVolume(500, outputID: "o1")
            .applied(to: zones, zoneID: "z1")[0].outputs[0].volume?.value, 100)
        XCTAssertEqual(TransportIntent.setVolume(-20, outputID: "o1")
            .applied(to: zones, zoneID: "z1")[0].outputs[0].volume?.value, 0)
    }

    func testSetMuted() {
        let zones = [zone(muted: false)]
        XCTAssertEqual(TransportIntent.setMuted(true, outputID: "o1")
            .applied(to: zones, zoneID: "z1")[0].outputs[0].volume?.isMuted, true)
    }

    func testVolumeIntentIgnoresOtherOutputs() {
        let zones = [zone(volume: 40, outputID: "o1")]
        let out = TransportIntent.setVolume(90, outputID: "ANDER").applied(to: zones, zoneID: "z1")
        XCTAssertEqual(out[0].outputs[0].volume?.value, 40)
    }

    func testOutputWithoutVolumeIsLeftAlone() {
        // A fixed-level output (pre-amp on the DAC) reports no volume block.
        let zones = [zone(volume: nil)]
        let out = TransportIntent.setVolume(50, outputID: "o1").applied(to: zones, zoneID: "z1")
        XCTAssertNil(out[0].outputs[0].volume)
    }

    // MARK: addressing

    func testUnknownZoneLeavesTheListUntouched() {
        let zones = [zone(id: "z1", state: .playing)]
        XCTAssertEqual(TransportIntent.togglePlayPause.applied(to: zones, zoneID: "onbekend"), zones)
    }

    func testOnlyTheNamedZoneChanges() {
        let zones = [zone(id: "z1", state: .playing), zone(id: "z2", state: .playing)]
        let out = TransportIntent.togglePlayPause.applied(to: zones, zoneID: "z2")
        XCTAssertEqual(out[0].state, .playing, "de andere zone mag niet meebewegen")
        XCTAssertEqual(out[1].state, .paused)
    }
}
