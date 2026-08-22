import AppKit
import Foundation
import RoonSageCore
import ServiceManagement

/// Guarantees exactly one analyzer server per machine, and one autostart route.
///
/// **The failure this prevents.** The analyzer registers with Roon as extension
/// `com.roonsage.server`. A Roon Core keeps ONE connection per extension id, so
/// a second copy of this app makes the two kick each other out in a loop. On
/// 2026-08-22 the mini ran two: one from the app's own "Start bij inloggen"
/// login item (`SMAppService`) and one from the `nl.roonsage.analyzer`
/// LaunchAgent, 17 seconds apart. The result was a reconnect every ~2 s (1.046
/// closes in one hour), and because a dropped connection cleared the zone list,
/// every client kept losing its zone. Nothing in the app noticed: both copies
/// looked healthy, they only made each other sick.
///
/// Two defences, in order:
/// 1. `enforce()` — refuse to be the second copy at all. launchd's copy wins
///    (it is the supervised one, and killing it would only make KeepAlive
///    respawn it); anything else steps aside and hands over focus.
/// 2. `reconcileAutostart()` — when the LaunchAgent is installed, unregister the
///    login item, so the duplicate is never created in the first place.
enum SingleInstance {

    /// Label of the LaunchAgent that runs the analyzer as server of record.
    static let launchAgentLabel = "nl.roonsage.analyzer"

    static var launchAgentPlistURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }

    /// True when launchd started this process (as opposed to Finder, Dock, or a
    /// login item — those come via LaunchServices, whose job label always starts
    /// with `application.`).
    static var startedByLaunchAgent: Bool {
        ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == launchAgentLabel
    }

    /// Other running copies of this exact app.
    private static var siblings: [NSRunningApplication] {
        guard let id = Bundle.main.bundleIdentifier else { return [] }
        let me = ProcessIdentifier(NSRunningApplication.current.processIdentifier)
        return NSRunningApplication.runningApplications(withBundleIdentifier: id)
            .filter { ProcessIdentifier($0.processIdentifier) != me }
    }

    private typealias ProcessIdentifier = pid_t

    /// Call as the very first thing in `init()`, before RoonClient is touched.
    /// Does not return when this process is the redundant copy.
    static func enforce() {
        let others = siblings
        guard !others.isEmpty else { return }

        guard startedByLaunchAgent else {
            // Someone opened the app while the supervised copy is already
            // running. Bring that one forward so the double-click still does
            // something visible, then get out of the way.
            Log.warning("er draait al een RoonSage Analyzer (pid \(others.map(\.processIdentifier))) — deze kopie sluit zichzelf af", category: .app)
            others.first?.activate(options: [.activateAllWindows])
            exit(0)
        }

        // We are launchd's copy: keep the supervised process and retire the
        // others. Exiting instead would hand the machine to an unsupervised
        // instance *and* make KeepAlive respawn us every 10 s.
        Log.warning("tweede RoonSage Analyzer gevonden (pid \(others.map(\.processIdentifier))) — die wordt afgesloten; één Roon-extensie per Core", category: .app)
        for app in others { app.terminate() }
        // Give a graceful quit a moment, then insist: a lingering copy keeps
        // kicking us off the Core, which is the whole problem.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, siblings.contains(where: { !$0.isTerminated }) {
            Thread.sleep(forTimeInterval: 0.25)
        }
        for app in siblings where !app.isTerminated { app.forceTerminate() }
    }

    /// Keep exactly one autostart route. The LaunchAgent is the documented
    /// server of record (KeepAlive, survives a crash), so when its plist is
    /// installed the app's own login item is redundant — and redundant here
    /// means "two servers fighting over one Roon extension".
    ///
    /// Returns true when it actually removed a login item.
    @discardableResult
    static func reconcileAutostart() -> Bool {
        guard #available(macOS 13.0, *) else { return false }
        guard FileManager.default.fileExists(atPath: launchAgentPlistURL.path) else { return false }
        guard SMAppService.mainApp.status == .enabled else { return false }
        do {
            try SMAppService.mainApp.unregister()
            Log.warning("login-item uitgezet: \(launchAgentLabel) start de analyzer al — twee autostarts gaven twee servers en een flapperende Roon-verbinding", category: .app)
            return true
        } catch {
            Log.error("login-item kon niet worden uitgezet: \(error.localizedDescription)", category: .app)
            return false
        }
    }
}
