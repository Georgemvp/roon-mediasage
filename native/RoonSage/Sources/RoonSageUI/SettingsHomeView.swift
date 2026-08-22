import RoonSageCore
import SwiftUI

/// Two doors instead of one wall.
///
/// `SettingsView` is 21 sections in a single `Form`, and it was gated by
/// `role` — server or client. That axis was wrong, and it cost real usability:
/// on 2026-08-11 four sections about how audio sounds on THIS device (loudness
/// levelling, the cellular AAC transcode, the audio cache, offline downloads)
/// turned out to sit inside `if role == .server` and were therefore invisible on
/// the phone, the one device they exist for (v1.10.257). The fix then was to
/// move four sections out of one `if`. This is the same lesson applied to the
/// structure: the question isn't "server or client" but **"does this configure
/// the server, or how it sounds here"**, and that answer now decides which page
/// a section appears on rather than living in a 300-line conditional.
///
/// Both the phone and the in-app sidebar use these two doors, so the two
/// platforms teach one vocabulary. `scope: .all` stays for the two places where
/// the settings are already a pane inside a bigger settings window and a second
/// level would be one too many: the macOS ⌘, scene (`RoonSageApp`) and the
/// analyzer app's own Server tab (`AnalyzerRootView`).
@MainActor
public struct SettingsHomeView: View {
    private let role: SettingsRole
    public init(role: SettingsRole = .client) { self.role = role }

    public var body: some View {
        List {
            Section {
                page(.device, LS("settings.thisDevice"),
                     LS("settings.thisDeviceSubtitle"), "iphone.gen3")
                page(.server, LS("settings.serverAndServices"),
                     LS("settings.serverAndServicesSubtitle"), "server.rack")
            } footer: {
                LT("settings.splitFooter")
            }
        }
        .navigationTitle(LS("nav.settings"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func page(_ scope: SettingsScope, _ title: String,
                      _ subtitle: String, _ icon: String) -> some View {
        NavigationLink {
            SettingsView(role: role, scope: scope)
        } label: {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: icon).foregroundStyle(Color.roonGold)
            }
        }
    }
}
