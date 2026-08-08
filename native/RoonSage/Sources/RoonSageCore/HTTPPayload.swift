import Compression
import CryptoKit
import Foundation

/// Bandwidth helpers for the share server: conditional GET and gzip.
///
/// `/library` is tens of megabytes on a 53k-track library and clients re-pull it
/// whenever the playback snapshot's `libraryRevision` shifts — which happens
/// during analysis, while the library CONTENT only changes on a sync. There was
/// no `ETag`, no `304` and no compression anywhere in the app (a repo-wide grep
/// for those returned nothing), so every one of those re-pulls shipped the whole
/// document uncompressed, over ZeroTier as often as over the LAN.
enum HTTPPayload {

    // MARK: - ETag

    /// Strong validator for a response body. Content-addressed, so it needs no
    /// bookkeeping: identical bytes always produce the same tag, which is exactly
    /// the property a conditional GET needs.
    static func etag(for body: Data) -> String {
        let digest = SHA256.hash(data: body).prefix(16)
        return "\"" + digest.map { String(format: "%02x", $0) }.joined() + "\""
    }

    // MARK: - gzip (RFC 1952)

    /// Smallest body worth compressing. Below roughly a TCP segment the gzip
    /// header + trailer costs more than the deflate saves.
    static let minimumCompressibleBytes = 1024

    static func clientAcceptsGzip(_ header: String) -> Bool {
        guard let accept = LibraryShareServer.headerValue("Accept-Encoding", in: header) else { return false }
        return accept.lowercased().contains("gzip")
    }

    /// Wrap raw DEFLATE in a gzip container. Apple's `COMPRESSION_ZLIB` emits raw
    /// DEFLATE (RFC 1951, stated in `compression.h`), so the header, CRC32 and
    /// ISIZE trailer that make it RFC 1952 gzip are added here. Returns nil when
    /// compression fails or does not actually shrink the body — the caller then
    /// sends it uncompressed rather than paying for a pointless round trip.
    static func gzip(_ body: Data) -> Data? {
        guard body.count >= minimumCompressibleBytes else { return nil }
        guard let deflated = rawDeflate(body), deflated.count < body.count else { return nil }

        var out = Data(capacity: deflated.count + 18)
        out.append(contentsOf: [
            0x1f, 0x8b,             // magic
            0x08,                   // CM = deflate
            0x00,                   // FLG = no extra fields
            0x00, 0x00, 0x00, 0x00, // MTIME = 0 (not stated; keeps output deterministic)
            0x00,                   // XFL
            0xff,                   // OS = unknown
        ])
        out.append(deflated)
        out.append(littleEndian: crc32(body))
        out.append(littleEndian: UInt32(truncatingIfNeeded: body.count))
        return out
    }

    private static func rawDeflate(_ body: Data) -> Data? {
        // Worst case DEFLATE expands slightly; the extra 64 KB covers that and the
        // per-block overhead on incompressible input.
        let capacity = body.count + 65_536
        var destination = [UInt8](repeating: 0, count: capacity)
        let written: Int = body.withUnsafeBytes { src -> Int in
            guard let base = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return compression_encode_buffer(&destination, capacity,
                                             base, body.count,
                                             nil, COMPRESSION_ZLIB)
        }
        // 0 means "could not compress into the destination buffer".
        guard written > 0 else { return nil }
        return Data(destination.prefix(written))
    }

    /// CRC-32 (IEEE 802.3, the polynomial gzip uses). Table built once.
    static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) == 1 ? (0xedb8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xffff_ffff
        for byte in data {
            c = crcTable[Int((c ^ UInt32(byte)) & 0xff)] ^ (c >> 8)
        }
        return c ^ 0xffff_ffff
    }
}

private extension Data {
    mutating func append(littleEndian value: UInt32) {
        append(contentsOf: [
            UInt8(truncatingIfNeeded: value),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 24),
        ])
    }
}
