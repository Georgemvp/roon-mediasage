import XCTest

/// Walks the app and photographs it, so "hoe ziet het eruit" stops being the one
/// question every UX commit had to leave open.
///
/// Six batches of interface work shipped with "NIET geverifieerd" in the commit
/// message, on the theory that this machine couldn't drive a GUI. XCUITest runs
/// *inside* the simulator through the test harness and needs no system
/// permission at all — it was available the whole time. Keep it that way: a walk
/// that leans on `osascript`/`screencapture` breaks the moment a TCC grant is
/// revoked, or on CI where there is no desktop to record.
///
/// This is a walk-and-photograph test, not an assertion suite. It asserts only
/// what would make the walk meaningless (a tab that isn't there, a button that
/// opens nothing); judging whether the result *looks* right stays a human job,
/// and the attachments are what that judgement is made on. Pull them out with
/// `native/scripts/ui-verify.sh`.
final class UXSnapshotTests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    /// The whole shell in one pass: past the gate, all four tabs, the settings
    /// split.
    func testWalkTheShell() throws {
        try enterOfflineMode()
        snap("01-bibliotheek")

        // By index, not by label. Every visible string in this app is localised
        // and the language a simulator boots in is not ours to assume — the very
        // first run of this test skipped because it looked for "Offline
        // gebruiken" on an English device. Position is the stable thing here,
        // and the count is the actual claim of batch 3.
        let tabs = app.tabBars.buttons
        XCTAssertEqual(tabs.count, 4,
                       "Verwacht vier tabs (Bibliotheek · Zoek · Ontdek · Stations)")

        for index in 1..<tabs.count {
            let tab = tabs.element(boundBy: index)
            let label = tab.label
            tab.tap()
            // A screenshot taken mid-transition shows the previous tab and lies.
            XCTAssertTrue(tab.wait(for: \.isSelected, toEqual: true, timeout: 5),
                          "Tab '\(label)' werd niet geselecteerd na een tik")
            snap(String(format: "%02d-tab-%@", index + 1, label))
        }

        tabs.element(boundBy: 0).tap()
        snap("05-bibliotheek-terug")

        try openSettings()
    }

    /// The player, which the shell exists to serve — and which no batch had ever
    /// photographed, because a seeded library without feature rows is a library
    /// where every play verb filters everything out. See `seed-demo-library.py`.
    func testPlayerAndQueue() throws {
        try enterOfflineMode()

        let tile = app.buttons.matching(identifier: "cover.tile").firstMatch
        guard tile.waitForExistence(timeout: 20) else {
            snap("10-geen-tegel")
            throw XCTSkip("Geen speelbare tegel op het overzicht — is de bibliotheek mét features gezaaid?")
        }
        tile.tap()

        // `descendants(matching: .any)`, not `otherElements`: the bar carries
        // `.accessibilityAddTraits(.isButton)`, and which element type XCUITest
        // then reports it as is not ours to assume.
        let bar = app.descendants(matching: .any)["nowplaying.bar"]
        guard bar.waitForExistence(timeout: 20) else {
            snap("10-geen-minibalk")
            return XCTFail("Er speelt niets na een tik op een tegel — de mini-balk kwam nooit")
        }
        snap("10-minibalk-speelt")

        // The whole point of batch 2: this opens a sheet OVER the library, it
        // does not throw you into another tab.
        bar.tap()
        _ = app.staticTexts.firstMatch.waitForExistence(timeout: 5)
        snap("11-speler")

        // And batch 5: the queue is one tap away, not an unannounced swipe.
        let queue = app.buttons.matching(NSPredicate(
            format: "label CONTAINS[c] 'wachtrij' OR label CONTAINS[c] 'queue'")).firstMatch
        if queue.exists {
            queue.tap()
            snap("12-wachtrij")
        } else {
            // Fall back to the swipe the button replaced, so a missing button is
            // visible in the photos rather than silently skipping the queue.
            app.swipeLeft()
            snap("12-wachtrij-via-veeg")
        }
    }

    /// Stations is four segments deep and only the first was ever seen.
    func testStationsSegments() throws {
        try enterOfflineMode()

        let tabs = app.tabBars.buttons
        guard tabs.count == 4 else { return XCTFail("Verwacht vier tabs, kreeg \(tabs.count)") }
        tabs.element(boundBy: 3).tap()
        XCTAssertTrue(tabs.element(boundBy: 3).wait(for: \.isSelected, toEqual: true, timeout: 5))

        let segments = app.segmentedControls.firstMatch
        guard segments.waitForExistence(timeout: 10) else {
            snap("20-geen-segmenten")
            return XCTFail("Stations toont geen moduskiezer")
        }
        for index in 0..<segments.buttons.count {
            let seg = segments.buttons.element(boundBy: index)
            let label = seg.label
            seg.tap()
            // The title bar is the claim under test here: every segment renders a
            // child that may set its own navigationTitle, overriding the tab's.
            _ = app.staticTexts.firstMatch.waitForExistence(timeout: 3)
            attachText("titel-bij-\(label)",
                       app.navigationBars.firstMatch.identifier)
            snap(String(format: "%02d-stations-%@", 20 + index, label))
        }
    }

    // MARK: - Steps

    /// The connect screen is the gate. With a library on disk the app usually
    /// slides into offline mode by itself once the connect attempt fails
    /// (`RoonClient.connectionState` didSet), so most runs never see the gate;
    /// when it does appear, press the button in whichever language it's in.
    private func enterOfflineMode() throws {
        if !app.tabBars.firstMatch.waitForExistence(timeout: 90) {
            let offline = app.buttons.matching(NSPredicate(
                format: "label IN {'Offline gebruiken', 'Use offline'}")).firstMatch
            guard offline.waitForExistence(timeout: 30) else {
                snap("00-vastgelopen-op-verbindscherm")
                throw XCTSkip("Geen weg voorbij het verbindscherm — is de demo-bibliotheek gezaaid?")
            }
            offline.tap()
            XCTAssertTrue(app.tabBars.firstMatch.waitForExistence(timeout: 30),
                          "Na 'Offline gebruiken' verscheen er geen tabbalk")
        }
        try startOnLibrary()
    }

    /// Land every test on the same tab.
    ///
    /// `RootView.restoreLastTab()` reopens whichever tab you last used, and the
    /// simulator's UserDefaults survive between test runs — so the second run of
    /// a suite opens on the tab the first one ended in. That is correct product
    /// behaviour and a trap for a walk: three tests failed at once ("no playable
    /// tile", "tab not selected") purely because they assumed tab 0.
    private func startOnLibrary() throws {
        let first = app.tabBars.buttons.element(boundBy: 0)
        guard first.waitForExistence(timeout: 10) else {
            snap("00-geen-tabbalk")
            throw XCTSkip("Geen tabbalk om vanaf te starten")
        }
        if !first.isSelected { first.tap() }
        XCTAssertTrue(first.wait(for: \.isSelected, toEqual: true, timeout: 10),
                      "Kon niet op Bibliotheek starten")
    }

    private func openSettings() throws {
        let gear = app.buttons["gear.settings"]
        guard gear.waitForExistence(timeout: 5) else {
            snap("06-geen-tandwiel")
            return XCTFail("Het tandwiel op Bibliotheek is onvindbaar — Instellingen is nergens meer")
        }

        // Where is it, really? The offline banner is a top safe-area inset on the
        // whole shell while the toolbar renders as a floating capsule; if those
        // overlap, a tap lands on the banner and nothing happens. Record the
        // frames before touching anything, so a failure here is diagnosable
        // instead of merely red.
        attachText("frames", [
            "gear:    \(gear.frame)",
            "hittable: \(gear.isHittable)",
            "window:  \(app.windows.firstMatch.frame)",
        ].joined(separator: "\n"))

        gear.tap()

        // A sheet takes about 0.4 s to arrive. The first version of this test
        // photographed the screen the instant after the tap and "proved" that
        // the gear did nothing.
        let arrived = app.navigationBars.count > 1
            || app.cells.firstMatch.waitForExistence(timeout: 5)
        snap("06-instellingen-twee-deuren")
        XCTAssertTrue(arrived, "Het tandwiel opende geen instellingenblad")

        // The first of the two doors, whatever it is called on this device.
        let device = app.cells.element(boundBy: 0)
        if device.waitForExistence(timeout: 5) {
            device.tap()
            _ = app.navigationBars.firstMatch.waitForExistence(timeout: 5)
            snap("07-instellingen-dit-apparaat")
        }
    }

    // MARK: - Plumbing

    private func attachText(_ name: String, _ body: String) {
        let note = XCTAttachment(string: body)
        note.name = name
        note.lifetime = .keepAlways
        add(note)
    }

    /// A full-screen shot, kept whether the test passes or fails — a green run
    /// that throws its evidence away is useless for a judgement call.
    private func snap(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }
}
