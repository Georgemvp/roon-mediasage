import AVFoundation
@testable import AudioAnalysis
import XCTest

/// Proves `AudioDecoder.decodeWindows` (the bounded-memory streaming path that
/// CLAP's `embed(url:)` now uses) emits the EXACT same window set as decoding the
/// whole track and striding over it the way `CLAPModel.embedWindowed` does. Same
/// windows → same per-window embeddings → byte-identical mean-direction embedding,
/// so the streaming rewrite does not change any stored vector (modelVersion stays
/// "v3"). Self-consistent: both paths read the same temp file, so exact float
/// equality is expected regardless of container quirks.
final class AudioDecoderWindowsTests: XCTestCase {
    private let sr = 48_000.0
    private let w = CLAPMel.clipSamples          // 480_000 (10 s)
    private var hop: Int { CLAPMel.clipSamples / 2 }   // 240_000 (5 s)

    /// Reference window set: mirrors `embedWindowed` — a single whole-buffer window
    /// when the track is <= one window, else strided starts + a flush-to-end tail.
    private func expectedWindows(_ s: [Float]) -> [[Float]] {
        guard s.count > w else { return [s] }
        var starts = Array(stride(from: 0, through: s.count - w, by: hop))
        let tail = s.count - w
        if starts.last != tail { starts.append(tail) }
        return starts.map { Array(s[$0..<$0 + w]) }
    }

    private func writeTempAudio(seconds: Double) throws -> URL {
        let n = Int(seconds * sr)
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr,
                                      channels: 1, interleaved: false) else {
            throw XCTSkip("cannot build write format")
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rs_decwin_\(n).wav")
        try? FileManager.default.removeItem(at: url)
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        var written = 0
        while written < n {
            let cap = min(48_000, n - written)
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(cap)) else {
                throw XCTSkip("cannot alloc write buffer")
            }
            buf.frameLength = AVAudioFrameCount(cap)
            let ch = buf.floatChannelData![0]
            for i in 0..<cap {
                let t = Double(written + i) / sr
                ch[i] = Float(0.3 * sin(2 * .pi * 220 * t) + 0.2 * sin(2 * .pi * 660 * t))
            }
            try file.write(from: buf)
            written += cap
        }
        return url
    }

    private func assertEquivalent(seconds: Double, file: StaticString = #filePath, line: UInt = #line) throws {
        let url = try writeTempAudio(seconds: seconds)
        defer { try? FileManager.default.removeItem(at: url) }

        let full = try AudioDecoder.decode(url: url, targetSampleRate: sr)
        let expected = expectedWindows(full.samples)

        var got: [[Float]] = []
        try AudioDecoder.decodeWindows(url: url, targetSampleRate: sr,
                                       windowSamples: w, hopSamples: hop) { got.append($0) }

        XCTAssertEqual(got.count, expected.count,
                       "window count mismatch @ \(seconds)s (\(full.samples.count) samples)",
                       file: file, line: line)
        for (i, (a, b)) in zip(got, expected).enumerated() {
            XCTAssertEqual(a.count, b.count, "window \(i) length @ \(seconds)s", file: file, line: line)
            XCTAssertEqual(a, b, "window \(i) samples differ @ \(seconds)s", file: file, line: line)
        }
    }

    /// Tail NOT on the hop grid → the flush-to-end window must be emitted.
    func testStreamingMatchesStrided_nonGridTail() throws { try assertEquivalent(seconds: 26.3) }

    /// Tail exactly on the grid → no extra tail window (last strided start == tail).
    func testStreamingMatchesStrided_gridAligned() throws { try assertEquivalent(seconds: 25.0) }

    /// A single hop past one window → exactly two windows (start + tail).
    func testStreamingMatchesStrided_justOverOneWindow() throws { try assertEquivalent(seconds: 15.0) }

    /// Track shorter than one window → a single whole-buffer window.
    func testStreamingMatchesStrided_shorterThanWindow() throws { try assertEquivalent(seconds: 7.0) }
}
