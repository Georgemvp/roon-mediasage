import AVFoundation
import XCTest
@testable import AnalyzerCore
@testable import RoonSageCore

/// The low-bitrate transcode path.
///
/// AAC-LC falls apart under ~112 kbps, which is exactly where you want to be on
/// mobile data. HE-AAC holds up far better there — but `AVAssetWriter` is picky
/// about it, so the encoder tries HE and falls back to LC. These prove both the
/// choice and the fallback, against real encoded audio rather than by assertion.
final class AudioTranscoderHEAACTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("transcode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    /// 6 seconds of 44.1 kHz stereo — a chord, so the encoder has real spectral
    /// content to work with rather than silence it can throw away.
    private func makeSourceWAV() throws -> URL {
        let url = dir.appendingPathComponent("source.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 2)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frames = AVAudioFrameCount(44_100)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for second in 0..<6 {
            for ch in 0..<2 {
                let data = buffer.floatChannelData![ch]
                for i in 0..<Int(frames) {
                    let t = Double(i) / 44_100
                    let v = sin(2 * .pi * 220 * t) + sin(2 * .pi * 277 * t) + sin(2 * .pi * 330 * t)
                    data[i] = Float(v / 3 * 0.6)
                }
            }
            _ = second
            try file.write(from: buffer)
        }
        return url
    }

    private func format(of url: URL) async throws -> AudioFormatID? {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first,
              let desc = try await track.load(.formatDescriptions).first else { return nil }
        return CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee.mFormatID
    }

    /// The wiring, not the unit. The HE path is only worth having if the bitrate
    /// the app actually asks for on cellular lands below the ceiling — with the
    /// old 256 kbps default the entire HE branch was unreachable dead code.
    func testCellularDefaultActuallyReachesTheHEPath() {
        XCTAssertLessThan(LocalTranscode.defaultBitrateKbps, AudioTranscoder.heAACCeiling,
                          "the default cellular bitrate must select HE-AAC, else the branch is dead")
        XCTAssertEqual(AudioTranscoder.aacFormat(forKbps: LocalTranscode.defaultBitrateKbps),
                       kAudioFormatMPEG4AAC_HE)
        // And a lossless source must not be waved through as "already small
        // enough" at that bitrate — otherwise the server serves FLAC anyway.
        XCTAssertTrue(AudioTranscoder.shouldTranscode(sourcePath: "/x/track.flac",
                                                      requestedKbps: LocalTranscode.defaultBitrateKbps))
    }

    /// The settings screen binds `@AppStorage` to the same keys the policy reads,
    /// so its defaults must BE the policy's defaults. They drifted once already:
    /// the picker said "Nooit" while the app transcoded on cellular.
    func testPolicyDefaultsAreCellularAndSurviveAnUnsetStore() {
        let store = UserDefaults.standard
        let savedMode = store.object(forKey: LocalTranscode.modeKey)
        let savedRate = store.object(forKey: LocalTranscode.bitrateKey)
        defer {
            savedMode.map { store.set($0, forKey: LocalTranscode.modeKey) }
            savedRate.map { store.set($0, forKey: LocalTranscode.bitrateKey) }
        }
        store.removeObject(forKey: LocalTranscode.modeKey)
        store.removeObject(forKey: LocalTranscode.bitrateKey)

        XCTAssertEqual(LocalTranscode.defaultMode, .cellular)
        // Nothing stored → the getters report the constants, which is exactly
        // what the settings picker displays.
        XCTAssertEqual(LocalTranscode.mode, .cellular)
        XCTAssertEqual(LocalTranscode.bitrateKbps, LocalTranscode.defaultBitrateKbps)
    }

    func testPicksHEAACOnlyBelowTheCeiling() {
        XCTAssertEqual(AudioTranscoder.aacFormat(forKbps: 64), kAudioFormatMPEG4AAC_HE)
        XCTAssertEqual(AudioTranscoder.aacFormat(forKbps: 96), kAudioFormatMPEG4AAC_HE)
        XCTAssertEqual(AudioTranscoder.aacFormat(forKbps: 128), kAudioFormatMPEG4AAC)
        XCTAssertEqual(AudioTranscoder.aacFormat(forKbps: 256), kAudioFormatMPEG4AAC)
    }

    /// The real thing: encode and read the result back.
    func testEncodesAtLowAndHighBitrate() async throws {
        let source = try makeSourceWAV()
        let sourceSize = try FileManager.default
            .attributesOfItem(atPath: source.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(sourceSize, 0)

        let low = dir.appendingPathComponent("low.m4a")
        let high = dir.appendingPathComponent("high.m4a")
        let lowOK = await AudioTranscoder.encode(source: source, dest: low, kbps: 64)
        let highOK = await AudioTranscoder.encode(source: source, dest: high, kbps: 256)
        XCTAssertTrue(lowOK, "64 kbps encode failed — HE and the LC fallback both gave up")
        XCTAssertTrue(highOK, "256 kbps encode failed")

        let lowSize = try FileManager.default.attributesOfItem(atPath: low.path)[.size] as? Int ?? 0
        let highSize = try FileManager.default.attributesOfItem(atPath: high.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(lowSize, 0)
        XCTAssertLessThan(lowSize, highSize, "64 kbps must be smaller than 256")
        XCTAssertLessThan(highSize, sourceSize, "a transcode that isn't smaller is pointless")

        // Both must be readable audio — a file that won't decode is worse than
        // no transcode at all, because the player would just fail silently.
        let lowFormat = try await format(of: low)
        let highFormat = try await format(of: high)
        XCTAssertNotNil(lowFormat, "64 kbps output is not decodable audio")
        XCTAssertEqual(highFormat, kAudioFormatMPEG4AAC, "256 kbps should be plain AAC-LC")
        // The low one is HE when the platform allowed it, LC when it fell back —
        // both are acceptable, an undecodable file is not.
        XCTAssertTrue(lowFormat == kAudioFormatMPEG4AAC_HE || lowFormat == kAudioFormatMPEG4AAC,
                      "unexpected format \(String(describing: lowFormat))")
    }
}
