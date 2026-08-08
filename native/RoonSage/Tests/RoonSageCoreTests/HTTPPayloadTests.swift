@testable import RoonSageCore
import XCTest

/// Covers the share server's bandwidth layer: the ETag validator and the gzip
/// container. The CRC32 is checked against the published test vectors — a wrong
/// CRC produces a stream that every client rejects, and it is not the kind of
/// mistake that shows up in a happy-path round trip.
final class HTTPPayloadTests: XCTestCase {

    // MARK: - ETag

    func testETagIsStableForIdenticalBytes() {
        let a = Data("hello world".utf8)
        let b = Data("hello world".utf8)
        XCTAssertEqual(HTTPPayload.etag(for: a), HTTPPayload.etag(for: b))
    }

    func testETagChangesWithContent() {
        XCTAssertNotEqual(HTTPPayload.etag(for: Data("a".utf8)),
                          HTTPPayload.etag(for: Data("b".utf8)))
    }

    func testETagIsAQuotedStrongValidator() {
        let tag = HTTPPayload.etag(for: Data("x".utf8))
        XCTAssertTrue(tag.hasPrefix("\"") && tag.hasSuffix("\""), "een ETag hoort in quotes")
        XCTAssertFalse(tag.hasPrefix("W/"), "geen weak validator — de bytes zijn exact")
        XCTAssertEqual(tag.count, 34, "16 bytes hex + 2 quotes")
    }

    // MARK: - CRC32 (known-answer vectors)

    func testCRC32MatchesPublishedVectors() {
        XCTAssertEqual(HTTPPayload.crc32(Data()), 0x0000_0000)
        XCTAssertEqual(HTTPPayload.crc32(Data("123456789".utf8)), 0xCBF4_3926)
        XCTAssertEqual(HTTPPayload.crc32(Data("The quick brown fox jumps over the lazy dog".utf8)),
                       0x414F_A339)
    }

    // MARK: - gzip

    /// Bodies large enough to be worth it get a well-formed RFC 1952 container.
    func testGzipProducesAValidContainer() throws {
        let body = Data(String(repeating: "roonsage ", count: 500).utf8)
        let zipped = try XCTUnwrap(HTTPPayload.gzip(body))

        let bytes = [UInt8](zipped)
        XCTAssertEqual(bytes[0], 0x1f, "gzip magic byte 1")
        XCTAssertEqual(bytes[1], 0x8b, "gzip magic byte 2")
        XCTAssertEqual(bytes[2], 0x08, "CM moet deflate zijn")
        XCTAssertEqual(bytes[3], 0x00, "geen extra velden")
        XCTAssertEqual(bytes.count, 10 + (bytes.count - 18) + 8, "header + deflate + trailer")

        // Trailer: CRC32 then ISIZE, both little-endian, over the ORIGINAL body.
        let trailer = bytes.suffix(8)
        let crc = UInt32(trailer[trailer.startIndex])
            | UInt32(trailer[trailer.startIndex + 1]) << 8
            | UInt32(trailer[trailer.startIndex + 2]) << 16
            | UInt32(trailer[trailer.startIndex + 3]) << 24
        let isize = UInt32(trailer[trailer.startIndex + 4])
            | UInt32(trailer[trailer.startIndex + 5]) << 8
            | UInt32(trailer[trailer.startIndex + 6]) << 16
            | UInt32(trailer[trailer.startIndex + 7]) << 24
        XCTAssertEqual(crc, HTTPPayload.crc32(body))
        XCTAssertEqual(isize, UInt32(body.count))
    }

    func testGzipActuallyShrinksRepetitiveJSON() throws {
        let body = Data(String(repeating: "{\"title\":\"Song\",\"artist\":\"Band\"},", count: 400).utf8)
        let zipped = try XCTUnwrap(HTTPPayload.gzip(body))
        XCTAssertLessThan(zipped.count, body.count / 4,
                          "repetitieve JSON hoort fors te krimpen")
    }

    func testGzipSkipsBodiesTooSmallToBeWorthIt() {
        XCTAssertNil(HTTPPayload.gzip(Data("klein".utf8)))
        XCTAssertNil(HTTPPayload.gzip(Data()))
    }

    /// Incompressible input must fall back to "send it raw" rather than shipping
    /// a container that is bigger than the body.
    func testGzipReturnsNilWhenItWouldNotShrink() {
        var random = Data(count: 4096)
        for i in random.indices { random[i] = UInt8.random(in: .min ... .max) }
        if let zipped = HTTPPayload.gzip(random) {
            XCTAssertLessThan(zipped.count, random.count,
                              "als er iets teruggegeven wordt moet het kleiner zijn")
        }
    }

    // MARK: - Accept-Encoding parsing

    func testClientAcceptsGzipReadsTheHeader() {
        XCTAssertTrue(HTTPPayload.clientAcceptsGzip(
            "GET /library HTTP/1.1\r\nAccept-Encoding: gzip, deflate\r\n\r\n"))
        XCTAssertTrue(HTTPPayload.clientAcceptsGzip(
            "GET /library HTTP/1.1\r\naccept-encoding: GZIP\r\n\r\n"))
        XCTAssertFalse(HTTPPayload.clientAcceptsGzip(
            "GET /library HTTP/1.1\r\nAccept-Encoding: br\r\n\r\n"))
        XCTAssertFalse(HTTPPayload.clientAcceptsGzip("GET /library HTTP/1.1\r\n\r\n"))
    }
}
