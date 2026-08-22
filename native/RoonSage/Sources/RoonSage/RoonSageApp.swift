import SwiftUI
import RoonSageCore
import RoonSageUI

@MainActor
@main
struct RoonSageApp: App {
    @State private var client: RoonClient
    @State private var availableUpdate: UpdateInfo? = nil
    @State private var showUpdateSheet = false
    @State private var isCheckingForUpdates = false
    @State private var installer = UpdateInstaller()

    init() {
        // This is a client: control Roon through the RoonSage server over HTTP,
        // never register a Roon extension on this Mac. Must run before connect.
        RoonClient.useServerMode()
        _client = State(initialValue: RoonClient.shared)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(client)
                .roonSageAppearance()
                .frame(minWidth: 900, minHeight: 600)
                .sheet(isPresented: $showUpdateSheet) {
                    if let update = availableUpdate {
                        UpdateView(update: update, installer: installer)
                    }
                }
                .task { await checkForUpdatesOnLaunch() }
                .task { await DiscoveryDigestNotifier.checkOnForeground(client: client) }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(after: .appInfo) {
                Divider()
                Button(isCheckingForUpdates ? LS("menu.checkingForUpdates") : LS("menu.checkForUpdates")) {
                    Task { await checkForUpdatesManually() }
                }
                .disabled(isCheckingForUpdates)
            }
            CommandMenu(LS("menu.controls")) {
                Button(LS("menu.playPause")) { transport { z in await client.playPause(zoneID: z) } }
                    .keyboardShortcut("p", modifiers: .command)
                Button(LS("root.nextTrack")) { transport { z in await client.next(zoneID: z) } }
                    .keyboardShortcut("]", modifiers: .command)
                Button(LS("root.previousTrack")) { transport { z in await client.previous(zoneID: z) } }
                    .keyboardShortcut("[", modifiers: .command)
                Divider()
                Button(LS("menu.volumeUp")) { volume(+4) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button(LS("menu.volumeDown")) { volume(-4) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .environment(client)
                .roonSageAppearance()
        }

        MenuBarExtra {
            MenuBarContent()
                .environment(client)
                .roonSageAppearance()
        } label: {
            Image(systemName: "music.note.house")
        }
        .menuBarExtraStyle(.window)
    }

    // MARK: - Transport shortcuts

    private func transport(_ action: @escaping (String) async -> Void) {
        guard let zone = client.selectedZone?.id else { return }
        Task { await action(zone) }
    }

    private func volume(_ delta: Int) {
        guard let output = client.selectedZone?.outputs.first?.id else { return }
        Task { await client.adjustVolume(outputID: output, delta: delta) }
    }

    // MARK: - Update checks

    private func checkForUpdatesOnLaunch() async {
        let lastCheckKey = "lastUpdateCheck"
        let now = Date().timeIntervalSince1970
        let last = UserDefaults.standard.double(forKey: lastCheckKey)
        guard now - last > 86400 else { return }
        UserDefaults.standard.set(now, forKey: lastCheckKey)

        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        if let update = await UpdateChecker.shared.checkForUpdates(currentVersion: currentVersion) {
            availableUpdate = update
            installer = UpdateInstaller()  // fresh installer for each update
            showUpdateSheet = true
        }
    }

    private func checkForUpdatesManually() async {
        isCheckingForUpdates = true
        defer { isCheckingForUpdates = false }

        let currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
        if let update = await UpdateChecker.shared.checkForUpdates(currentVersion: currentVersion) {
            availableUpdate = update
            installer = UpdateInstaller()
            showUpdateSheet = true
        } else {
            let alert = NSAlert()
            alert.messageText = LS("menu.upToDateTitle")
            alert.informativeText = String(format: LS("menu.upToDateBody"), currentVersion)
            alert.alertStyle = .informational
            alert.addButton(withTitle: LS("menu.ok"))
            alert.runModal()
        }
    }
}
