import Foundation

/// Timestamped lyrics, parsed.
///
/// This lives in `AudioAnalysis` rather than beside `LyricsService` for one
/// reason: the analyser needs it too. `AnalyzerCore` reads `.lrc` sidecars and
/// embedded ID3 frames off the music volume, and it cannot import
/// `RoonSageCore` (the dependency runs the other way). Parsing LRC in two
/// places is how two parsers drift — one accepting `[00:12]` and the other not
/// — so there is one, here, and `LyricsService.parseLRC` forwards to it.
///
/// Pure Foundation: no AVFoundation, no platform types.
public enum LRCParser {

    /// One timestamped line. Deliberately NOT `RoonSageCore.LyricLine`: that
    /// type is part of the client's wire format and this module sits below it.
    /// The two are mapped at the single boundary in `LyricsService`.
    public struct Line: Sendable, Equatable {
        public let time: Double     // seconds from track start
        public let text: String
        public init(time: Double, text: String) {
            self.time = time
            self.text = text
        }
    }

    /// Parse an LRC string into timestamped lines. Handles multiple timestamps
    /// per line (`[00:12.00][00:47.00] text`), `mm:ss.xx` and `mm:ss` forms, and
    /// skips ID-tag lines (`[ar:…]`, `[ti:…]`). Blank lyric lines are kept as
    /// pauses — a gap you can see is part of how a karaoke view reads.
    public static func parse(_ raw: String) -> [Line] {
        var out: [Line] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            var s = Substring(line)
            var stamps: [Double] = []
            while s.first == "[" {
                guard let close = s.firstIndex(of: "]") else { break }
                let tag = s[s.index(after: s.startIndex)..<close]
                if let secs = parseStamp(String(tag)) { stamps.append(secs) }
                else if !stamps.isEmpty { break }   // stop at a non-time tag once we've seen times
                s = s[s.index(after: close)...]
            }
            guard !stamps.isEmpty else { continue }
            let text = s.trimmingCharacters(in: .whitespaces)
            for t in stamps { out.append(Line(time: t, text: text)) }
        }
        return out.sorted { $0.time < $1.time }
    }

    /// Parse a `mm:ss`, `mm:ss.xx` or `mm:ss.xxx` timestamp to seconds; nil for
    /// non-time tags (ID metadata).
    public static func parseStamp(_ tag: String) -> Double? {
        let parts = tag.split(separator: ":")
        guard parts.count == 2, let minutes = Double(parts[0]) else { return nil }
        guard let seconds = Double(parts[1]) else { return nil }
        return minutes * 60 + seconds
    }

    /// Strip every timestamp, leaving the plain text — what a file that carries
    /// ONLY an LRC still owes a reader who just wants the words.
    public static func plainText(_ raw: String) -> String {
        parse(raw).map(\.text).filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

// MARK: - ID3 SYLT (synchronised lyric/text)

/// Decoder for the ID3v2 `SYLT` frame, which AVFoundation hands over as raw
/// bytes rather than a string.
///
/// Frame layout (ID3v2.3/2.4 §4.10), after the frame header AVFoundation has
/// already stripped:
///
///     $xx           text encoding
///     $xx xx xx     language (3 bytes, ISO-639-2)
///     $xx           time-stamp format (1 = MPEG frames, 2 = milliseconds)
///     $xx           content type (1 = lyrics)
///     <text string according to encoding> $00 (00)   content descriptor
///     then, repeated:
///       <sync text> $00 (00)   terminated string
///       $xx xx xx xx           timestamp, big-endian
///
/// Only `timestampFormat == 2` (milliseconds) is decoded. Format 1 counts MPEG
/// audio frames, which cannot be converted to seconds without the file's frame
/// rate — guessing 26 ms/frame would silently desynchronise the whole track,
/// which is worse than showing plain lyrics.
public enum SYLTParser {

    /// Decode a SYLT payload into timestamped lines, or `nil` when the frame is
    /// truncated, uses an undecodable encoding, or counts MPEG frames.
    public static func parse(_ data: Data) -> [LRCParser.Line]? {
        let bytes = [UInt8](data)
        // 1 encoding + 3 language + 1 format + 1 content type = 6, plus at least
        // a terminator for the descriptor.
        guard bytes.count > 6 else { return nil }

        let encodingByte = bytes[0]
        guard let encoding = textEncoding(encodingByte) else { return nil }
        let timestampFormat = bytes[4]
        guard timestampFormat == 2 else { return nil }   // MPEG frames: not convertible here

        // Terminator width follows the encoding: UTF-16 strings end in two NULs.
        let terminatorWidth = (encodingByte == 1 || encodingByte == 2) ? 2 : 1

        var i = 6
        // Skip the content descriptor.
        guard let afterDescriptor = endOfString(bytes, from: i, width: terminatorWidth) else { return nil }
        i = afterDescriptor

        var out: [LRCParser.Line] = []
        while i + terminatorWidth + 4 <= bytes.count {
            guard let end = endOfString(bytes, from: i, width: terminatorWidth) else { break }
            let textBytes = Array(bytes[i..<(end - terminatorWidth)])
            guard end + 4 <= bytes.count else { break }
            let ms = (UInt32(bytes[end]) << 24) | (UInt32(bytes[end + 1]) << 16)
                   | (UInt32(bytes[end + 2]) << 8) | UInt32(bytes[end + 3])
            let text = String(data: Data(textBytes), encoding: encoding) ?? ""
            // SYLT splits a line into syllables in some taggers; a leading
            // newline marks a real line break. Trim it — the view lays lines
            // out itself and a stray "\n" renders as an empty row.
            let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            out.append(LRCParser.Line(time: Double(ms) / 1000, text: cleaned))
            i = end + 4
        }
        return out.isEmpty ? nil : out.sorted { $0.time < $1.time }
    }

    /// Index just past the terminator of the string starting at `from`, or nil
    /// when the buffer runs out first (a truncated frame).
    private static func endOfString(_ bytes: [UInt8], from: Int, width: Int) -> Int? {
        var i = from
        while i + width <= bytes.count {
            if width == 1 {
                if bytes[i] == 0 { return i + 1 }
                i += 1
            } else {
                // UTF-16 terminators are aligned to the code-unit grid; scanning
                // byte-by-byte would match the high byte of an ASCII character.
                if bytes[i] == 0 && bytes[i + 1] == 0 { return i + 2 }
                i += 2
            }
        }
        return nil
    }

    /// ID3v2.4 text encodings. `nil` for values outside the spec — an unknown
    /// encoding byte means the frame is not what we think it is.
    private static func textEncoding(_ byte: UInt8) -> String.Encoding? {
        switch byte {
        case 0: return .isoLatin1
        case 1: return .utf16          // with BOM
        case 2: return .utf16BigEndian // without BOM
        case 3: return .utf8
        default: return nil
        }
    }
}
