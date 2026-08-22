import RoonSageCore
import SwiftUI

/// The Zoek tab — one door for the three ways this app can find music.
///
/// They used to be three separate destinations you had to know the names of:
/// the library search lived in the Bibliotheek screen, the CLAP search behind
/// Ontdek → Sonic Lab → segment "Zoek", and "Vraag het" behind Maak → hub →
/// segment "Snel". Three audits (`KOEL_AUDIT` K3, `JELLYFIN_AUDIT` J6, readiness
/// P7) pointed at that; P7 merged artist/album/track into one box, and this puts
/// that box one tap from anywhere.
///
///   - Bibliotheek — literal matching over the local GRDB (`UnifiedSearch`),
///                   works offline
///   - Sonisch     — the words become a CLAP vector; "dromerige nachtpiano"
///                   matches nothing literal but plenty sonically
///   - Vraag het   — the same question, answered by the LLM over your library
///
/// The three views are reused as they are: `LibraryView(searchOnly:)` carries
/// the whole combined-result machinery including the "toon alles" drill-down and
/// the hand-off into the sonic tab.
@MainActor
public struct SearchView: View {
    public init() {}

    enum Mode: String, CaseIterable, Identifiable {
        case library, sonic, ask
        var id: String { rawValue }
        var label: String {
            switch self {
            case .library: LS("nav.library")
            case .sonic:   LS("sonicLab.modeSearch")
            case .ask:     LS("nav.ask")
            }
        }
    }

    @State private var mode: Mode = .library

    public var body: some View {
        VStack(spacing: 0) {
            Picker(LS("search.modePickerTitle"), selection: $mode) {
                ForEach(Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch mode {
            case .library: LibraryView(searchOnly: true)
            case .sonic:   SonicSearchView()
            case .ask:     AskView()
            }
        }
        // The tab already carries the name; a segment's child must not
        // rename it out from under us. See `ScreenTitle.swift`.
        .hubContent()
    }
}
