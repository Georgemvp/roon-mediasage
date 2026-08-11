import XCTest
@testable import RoonSageCore

/// Core's own user-facing messages.
///
/// Core sits below the string catalogue, so it hardcoded Dutch and an English
/// app showed sentences like "Stop afspelen op this device". The translator is
/// injected — which means the interesting cases are all the ways injection can
/// be absent or unhelpful, because each of those must degrade to readable Dutch
/// rather than to a raw key on screen.
final class CoreStringsTests: XCTestCase {

    override func tearDown() {
        CoreStrings.reset()
        super.tearDown()
    }

    func testFallsBackWhenNoTranslatorIsRegistered() {
        CoreStrings.reset()
        XCTAssertEqual(CoreStrings.s("core.error.noServer", "Geen verbinding."), "Geen verbinding.")
    }

    func testUsesTheRegisteredTranslation() {
        CoreStrings.register { $0 == "core.error.noServer" ? "No connection." : nil }
        XCTAssertEqual(CoreStrings.s("core.error.noServer", "Geen verbinding."), "No connection.")
    }

    /// An unknown key must fall back, not surface. This is the exact failure a
    /// user screenshot caught in the UI layer on 2026-08-10, where a missing key
    /// rendered as "localNowPlaying.nothingPlaying".
    func testUnknownKeyFallsBackInsteadOfShowingTheKey() {
        CoreStrings.register { _ in nil }
        XCTAssertEqual(CoreStrings.s("core.error.mystery", "Er ging iets mis."), "Er ging iets mis.")
    }

    /// A translator that echoes the key back — the shape `Bundle.localizedString`
    /// has by default — must be treated as a miss, not as a translation.
    func testEchoedKeyIsTreatedAsMissing() {
        CoreStrings.register { $0 }
        XCTAssertEqual(CoreStrings.s("core.error.noServer", "Geen verbinding."), "Geen verbinding.")
    }

    func testEmptyTranslationFallsBack() {
        CoreStrings.register { _ in "" }
        XCTAssertEqual(CoreStrings.s("core.error.noServer", "Geen verbinding."), "Geen verbinding.")
    }

    func testFormatsArgumentsIntoTheFallback() {
        CoreStrings.reset()
        XCTAssertEqual(
            CoreStrings.f("core.error.queueSomeFailed", "%1$d van de %2$d tracks konden niet.", 3, 12),
            "3 van de 12 tracks konden niet.")
    }

    /// Positional placeholders matter: a translation is allowed to reorder them,
    /// and `String(format:)` must honour that rather than filling left to right.
    func testTranslationMayReorderPositionalArguments() {
        CoreStrings.register { _ in "%2$d tracks, waarvan %1$d mislukt" }
        XCTAssertEqual(CoreStrings.f("core.error.queueSomeFailed", "onbereikbaar", 3, 12),
                       "12 tracks, waarvan 3 mislukt")
    }

    /// The last registration wins — the app registers once at launch, but tests
    /// and a language switch both re-register.
    func testReRegisteringReplacesTheTranslator() {
        CoreStrings.register { _ in "eerste" }
        CoreStrings.register { _ in "tweede" }
        XCTAssertEqual(CoreStrings.s("k.k", "fallback"), "tweede")
    }
}

/// The catalogue, read off disk.
///
/// An earlier attempt tried to prove this through the real `Bundle` lookup and
/// could not: inside `swift test` the UI resource bundle isn't beside the
/// executable, so `uiBundle` degrades to `.main` (the xctest runner) and even
/// `LS("nav.settings")` misses. That's a property of the test process, not of
/// the app — but it means bundle *resolution* is unprovable here, so this reads
/// the `.strings` files directly and checks the two things that can actually
/// rot: a key Core asks for that nobody translated, and a format string whose
/// placeholders don't match the arguments Core passes.
///
/// The second one is not cosmetic. `String(format: "%@ tracks", 3)` with an Int
/// reads the argument as a pointer.
final class CoreStringsCatalogueTests: XCTestCase {

    private func catalogue(_ lang: String) throws -> [String: String] {
        let root = URL(fileURLWithPath: #filePath)      // …/Tests/RoonSageCoreTests/<this>
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent(
            "Sources/RoonSageUI/Resources/\(lang).lproj/Localizable.strings")
        let text = try String(contentsOf: url, encoding: .utf8)
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") {
            guard line.hasPrefix("\""), let eq = line.range(of: "\" = \"") else { continue }
            let key = String(line[line.index(after: line.startIndex)..<eq.lowerBound])
            var value = String(line[eq.upperBound...])
            if let end = value.range(of: "\";", options: .backwards) { value = String(value[..<end.lowerBound]) }
            out[key] = value
        }
        return out
    }

    /// Every `CoreStrings` key used in Core source, found by scanning the source
    /// itself — a hand-maintained list would drift the moment someone adds a
    /// message, which is the drift this test exists to catch.
    private func keysUsedInCore() throws -> Set<String> {
        let core = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/RoonSageCore")
        var keys = Set<String>()
        let files = FileManager.default.enumerator(at: core, includingPropertiesForKeys: nil)
        let pattern = try NSRegularExpression(
            pattern: #"CoreStrings\.[sf]\(\s*"([a-zA-Z][a-zA-Z0-9.]*)""#)
        while let url = files?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                  let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let ns = text as NSString
            for m in pattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                keys.insert(ns.substring(with: m.range(at: 1)))
            }
        }
        return keys
    }

    func testEveryCoreKeyIsTranslatedInBothLanguages() throws {
        let used = try keysUsedInCore()
        XCTAssertGreaterThan(used.count, 15, "the source scan found suspiciously few keys")
        for lang in ["nl", "en"] {
            let table = try catalogue(lang)
            let missing = used.subtracting(table.keys).sorted()
            XCTAssertTrue(missing.isEmpty, "\(lang) is missing: \(missing.joined(separator: ", "))")
        }
    }

    /// Placeholders must agree between the two languages. A translation that
    /// drops or adds one turns a formatted message into garbage — or worse,
    /// reads an Int as a pointer.
    func testFormatSpecifiersMatchAcrossLanguages() throws {
        let nl = try catalogue("nl"), en = try catalogue("en")
        for key in try keysUsedInCore().sorted() {
            guard let a = nl[key], let b = en[key] else { continue }
            XCTAssertEqual(Self.specifiers(a), Self.specifiers(b),
                           "placeholder mismatch for \(key): nl=\(a) en=\(b)")
        }
    }

    /// Conversion characters in order, ignoring any positional `n$` prefix —
    /// reordering IS allowed, changing the types is not.
    static func specifiers(_ s: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: #"%(?:(\d+)\$)?([@dif])"#) else { return [] }
        let ns = s as NSString
        var out: [(pos: Int, conv: String)] = []
        for (i, m) in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).enumerated() {
            let posRange = m.range(at: 1)
            let pos = posRange.location == NSNotFound ? i + 1 : Int(ns.substring(with: posRange)) ?? i + 1
            out.append((pos, ns.substring(with: m.range(at: 2))))
        }
        return out.sorted { $0.pos < $1.pos }.map(\.conv)
    }
}
