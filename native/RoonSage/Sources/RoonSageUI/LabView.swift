import RoonSageCore
import SwiftUI

/// Lab — the power tools, in one place instead of scattered over a tab.
///
/// Music Map, Sonic DNA, Multitag and the DJ mixer are genuinely useful and
/// genuinely rare: you open them on purpose, not while looking for something to
/// play. They used to sit in the tab bar's "Ontdek" cupboard, which meant two of
/// five tabs were lists that linked to hubs — navigation furniture where content
/// should be. Nothing is removed; it moved behind one card on the library
/// overview, and everything here is still one ⌘K away by name.
@MainActor
public struct LabView: View {
    public init() {}

    public var body: some View {
        List {
            Section(LS("lab.sectionSonic")) {
                row(LS("nav.sonicLab"), LS("lab.sonicLabSubtitle"),
                    SidebarItem.sonicLab.icon) { SonicLabView().navigationTitle(LS("nav.sonicLab")) }
                row("Music Map", LS("lab.musicMapSubtitle"),
                    SidebarItem.musicMap.icon) { MusicMapView().navigationTitle("Music Map") }
                row(LS("nav.multitag"), LS("lab.multitagSubtitle"),
                    SidebarItem.multitag.icon) { MultitagView() }
            }
            Section("DJ") {
                row(LS("nav.dj"), LS("lab.djSubtitle"),
                    SidebarItem.dj.icon) { DJView().navigationTitle("DJ") }
            }
            Section(LS("section.you")) {
                row(LS("nav.tasteHub"), LS("lab.tasteSubtitle"),
                    SidebarItem.tasteHub.icon) { TasteHubView().navigationTitle(LS("nav.tasteHub")) }
            }
        }
        .navigationTitle(LS("nav.lab"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// One row: name, one line of plain language about what it does, and the
    /// destination. The subtitle matters more here than anywhere else in the app
    /// — "Sonic DNA" and "Multitag" tell a newcomer nothing on their own.
    private func row<D: View>(_ title: String, _ subtitle: String, _ icon: String,
                              @ViewBuilder destination: @escaping () -> D) -> some View {
        NavigationLink {
            destination()
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
