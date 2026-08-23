@testable import AnalyzerCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

/// Album art for analyser-sourced library rows (AnalyzerCore/ArtworkProvider):
/// sidecar lookup, downscaling and content-type sniffing. The embedded-artwork
/// path needs a real tagged audio file and is covered by the analyser's own
/// walk, not here.
final class ArtworkProviderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("roonsage-artwork-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let dir { try? FileManager.default.removeItem(at: dir) }
    }

    private func touch(_ name: String) throws {
        try Data([0x00]).write(to: dir.appendingPathComponent(name))
    }

    private var track: URL { dir.appendingPathComponent("01 - Chaconne.flac") }

    /// A real, decodable PNG so the ImageIO paths are exercised for what they
    /// are, not for a hand-rolled byte array.
    private func makePNG(width: Int, height: Int) throws -> Data {
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: 0, space: cs,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(ctx.makeImage())
        let out = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return out as Data
    }

    // MARK: - Sidecar lookup

    func testPrefersCoverOverOtherNames() throws {
        try touch("back.jpg")
        try touch("folder.jpg")
        try touch("cover.jpg")
        let found = try XCTUnwrap(ArtworkProvider.sidecarURL(besideFile: track))
        XCTAssertEqual(found.lastPathComponent, "cover.jpg")
    }

    func testFallsBackDownThePreferenceOrder() throws {
        try touch("folder.png")
        let found = try XCTUnwrap(ArtworkProvider.sidecarURL(besideFile: track))
        XCTAssertEqual(found.lastPathComponent, "folder.png")
    }

    func testMatchesCaseInsensitivelyAndKeepsTheRealName() throws {
        // The music volume isn't guaranteed to be case-insensitive, so the match
        // is lowercased but the returned path must be the name on disk.
        try touch("Cover.JPG")
        let found = try XCTUnwrap(ArtworkProvider.sidecarURL(besideFile: track))
        XCTAssertEqual(found.lastPathComponent, "Cover.JPG")
        XCTAssertTrue(FileManager.default.fileExists(atPath: found.path))
    }

    func testNoSidecarIsNil() throws {
        try touch("notes.txt")
        try touch("back.jpg")   // not in the preference list
        XCTAssertNil(ArtworkProvider.sidecarURL(besideFile: track))
    }

    // MARK: - Downscaling

    func testDownscaleShrinksTheLongEdge() throws {
        let big = try makePNG(width: 1500, height: 1500)
        let small = try XCTUnwrap(ArtworkProvider.downscale(big, maxPixel: 200))
        let src = try XCTUnwrap(CGImageSourceCreateWithData(small as CFData, nil))
        let props = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any])
        XCTAssertEqual(props[kCGImagePropertyPixelWidth] as? Int, 200)
        XCTAssertLessThan(small.count, big.count)
        XCTAssertEqual(ArtworkProvider.sniffContentType(small), "image/jpeg")
    }

    func testDownscaleOfGarbageIsNilSoTheCallerCanServeTheOriginal() {
        XCTAssertNil(ArtworkProvider.downscale(Data("not an image".utf8), maxPixel: 200))
    }

    // MARK: - Content-type sniffing

    func testSniffsTheFormatsAnEmbeddedCoverCanBe() throws {
        XCTAssertEqual(ArtworkProvider.sniffContentType(try makePNG(width: 8, height: 8)), "image/png")
        XCTAssertEqual(ArtworkProvider.sniffContentType(Data([0xFF, 0xD8, 0xFF, 0xE0])), "image/jpeg")
        XCTAssertEqual(
            ArtworkProvider.sniffContentType(Data([0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x45, 0x42, 0x50])),
            "image/webp")
        // An unknown payload must not be announced as an image: a wrong type is
        // worse than a generic one, the client renders a broken tile either way.
        XCTAssertEqual(ArtworkProvider.sniffContentType(Data("hello".utf8)), "application/octet-stream")
    }
}
