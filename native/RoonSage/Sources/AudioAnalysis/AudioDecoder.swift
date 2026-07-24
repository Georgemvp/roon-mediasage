import AVFoundation
import Foundation

public enum AudioDecodeError: Error {
    case formatFailed
    case converterFailed
}

public struct DecodedAudio: Sendable {
    public let samples: [Float]      // mono (possibly an excerpt)
    public let sampleRate: Double
    public var fullDurationSec: Double = 0   // duration of the WHOLE track
    public var duration: Double { sampleRate > 0 ? Double(samples.count) / sampleRate : 0 }
}

/// Decodes any AVFoundation-supported file (FLAC/ALAC/AAC/MP3/WAV/AIFF on
/// modern macOS) to mono Float32 at a target analysis sample rate.
public struct AudioDecoder {

    /// Decode (optionally just an excerpt) to mono Float32 at `targetSampleRate`.
    /// `maxSeconds > 0` reads only a bounded segment starting at `startFraction`
    /// of the track — far less I/O on slow drives, and representative for
    /// BPM/key/energy. `startFraction` is clamped so the window fits.
    public static func decode(
        url: URL,
        targetSampleRate: Double = 22050,
        maxSeconds: Double = 0,
        startFraction: Double = 0
    ) throws -> DecodedAudio {
        var samples = [Float]()
        let fullDuration = try streamConvert(
            url: url, targetSampleRate: targetSampleRate,
            maxSeconds: maxSeconds, startFraction: startFraction,
            onEstimate: { samples.reserveCapacity($0) },
            onChunk: { samples.append(contentsOf: $0) })
        return DecodedAudio(samples: samples, sampleRate: targetSampleRate, fullDurationSec: fullDuration)
    }

    /// Decode to mono Float32 and emit fixed-size overlapping windows WITHOUT ever
    /// holding the whole track in memory — the bounded-footprint path for CLAP's
    /// full-track embedding (a 30-min hi-res track is otherwise ~345 MB of PCM per
    /// in-flight file). Windows are `windowSamples` long, advanced by `hopSamples`,
    /// starting at absolute samples 0, hop, 2·hop, …, PLUS a final flush-to-end
    /// window `[total-windowSamples, total)` when the last hop didn't already land
    /// there — reproducing `CLAPModel.embedWindowed`'s window set exactly, so the
    /// mean-direction embedding is byte-identical to the decode-all path. Tracks
    /// shorter than one window emit a single (short) window covering everything.
    ///
    /// `emit` receives each window as its own `[Float]`; peak memory is one window
    /// plus a bounded sliding buffer, not the full track.
    public static func decodeWindows(
        url: URL,
        targetSampleRate: Double,
        windowSamples: Int,
        hopSamples: Int,
        maxSeconds: Double = 0,
        _ emit: (_ window: [Float]) throws -> Void
    ) throws {
        precondition(windowSamples > 0 && hopSamples > 0, "window/hop must be positive")
        let w = windowSamples, hop = hopSamples
        var buf = [Float]()            // sliding buffer; buf[0] is absolute index `bufStart`
        var bufStart = 0               // absolute index of buf[0]
        var total = 0                  // total samples produced so far (== bufStart + buf.count)
        var nextStart = 0              // next window start to emit (absolute)
        var lastEmitted = -1           // last emitted absolute start (for the tail check)

        _ = try streamConvert(
            url: url, targetSampleRate: targetSampleRate,
            maxSeconds: maxSeconds, startFraction: 0,
            onChunk: { chunk in
                buf.append(contentsOf: chunk)
                total += chunk.count
                while nextStart + w <= total {                 // a full window is available
                    let lo = nextStart - bufStart
                    try emit(Array(buf[lo..<lo + w]))
                    lastEmitted = nextStart
                    nextStart += hop
                    // Compact the front, but retain the trailing `w` samples so the
                    // EOF tail window is always reconstructable. keepFrom == nextStart
                    // during steady streaming (total-w is ahead of nextStart).
                    let keepFrom = min(nextStart, max(0, total - w))
                    if keepFrom > bufStart {
                        buf.removeFirst(keepFrom - bufStart)
                        bufStart = keepFrom
                    }
                }
            })

        if lastEmitted < 0 {
            // Track shorter than one window (or empty): emit everything once, mirroring
            // embedWindowed's `guard samples.count > w else { embed(samples:) }`.
            if !buf.isEmpty { try emit(Array(buf[0..<buf.count])) }
            return
        }
        let tail = total - w
        if tail > lastEmitted && tail >= bufStart {            // flush-to-end window
            let lo = tail - bufStart
            try emit(Array(buf[lo..<lo + w]))
        }
    }

    /// Shared read+convert engine for `decode` and `decodeWindows`. Reads the file
    /// in chunks, converts to mono Float32 at `targetSampleRate`, and hands each
    /// produced buffer to `onChunk`. `onEstimate` (optional) receives an output-size
    /// hint before the loop so callers that accumulate can reserve capacity.
    /// Returns the WHOLE track's duration in seconds. The sample stream is identical
    /// regardless of the sink, so both callers see the same PCM.
    @discardableResult
    private static func streamConvert(
        url: URL,
        targetSampleRate: Double,
        maxSeconds: Double,
        startFraction: Double,
        onEstimate: (_ estimatedOutputSamples: Int) -> Void = { _ in },
        onChunk: (_ chunk: UnsafeBufferPointer<Float>) throws -> Void
    ) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        let inFormat = file.processingFormat
        let totalFrames = AVAudioFrameCount(file.length)
        guard totalFrames > 0 else { return 0 }

        var startFrame: AVAudioFramePosition = 0
        var framesToRead = totalFrames
        if maxSeconds > 0 {
            let want = AVAudioFrameCount(maxSeconds * inFormat.sampleRate)
            if want < totalFrames {
                framesToRead = want
                let raw = AVAudioFramePosition(Double(totalFrames) * max(0, min(1, startFraction)))
                startFrame = max(0, min(raw, AVAudioFramePosition(totalFrames - want)))
            }
        }

        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: targetSampleRate,
            channels: 1,
            interleaved: false
        ), let converter = AVAudioConverter(from: inFormat, to: outFormat) else {
            throw AudioDecodeError.converterFailed
        }

        // Chunked read+convert: a whole hi-res track no longer needs one giant
        // input buffer (a 20-min 192 kHz stereo file would be ~1.8 GB one-shot).
        // The converter keeps its resample state across chunks, so the output
        // matches the previous single-shot path.
        let chunkFrames: AVAudioFrameCount = 1 << 18   // input frames per read (~1.4-6 s; a few MB)
        var remaining = framesToRead
        if startFrame > 0 { file.framePosition = startFrame }

        let ratio = targetSampleRate / inFormat.sampleRate
        onEstimate(Int(Double(framesToRead) * ratio) + 8192)
        let outCapacity = AVAudioFrameCount(Double(chunkFrames) * ratio) + 8192
        var readError: Error?

        // chunkFrames=4: framesToRead=0 -> 0 reads; 3 -> read 3, EOS; 9 -> 4+4+1, EOS.
        conversion: while true {
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
                throw AudioDecodeError.formatFailed
            }
            var convErr: NSError?
            let status = converter.convert(to: outBuf, error: &convErr) { _, outStatus in
                guard remaining > 0, readError == nil else { outStatus.pointee = .endOfStream; return nil }
                let toRead = min(chunkFrames, remaining)
                guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: toRead) else {
                    readError = AudioDecodeError.formatFailed
                    outStatus.pointee = .endOfStream
                    return nil
                }
                do { try file.read(into: inBuf, frameCount: toRead) } catch {
                    readError = error
                    outStatus.pointee = .endOfStream
                    return nil
                }
                guard inBuf.frameLength > 0 else { remaining = 0; outStatus.pointee = .endOfStream; return nil }
                remaining -= min(remaining, inBuf.frameLength)   // min() guards UInt32 underflow
                outStatus.pointee = .haveData
                return inBuf
            }
            if let convErr { throw convErr }
            if let readError { throw readError }
            let produced = Int(outBuf.frameLength)
            if produced > 0, let ch = outBuf.floatChannelData?[0] {
                try onChunk(UnsafeBufferPointer(start: ch, count: produced))
            }
            switch status {
            case .endOfStream, .error: break conversion
            default: if produced == 0 { break conversion }   // defensive: no progress
            }
        }

        return Double(totalFrames) / inFormat.sampleRate
    }
}
