import RoonSageCore
import SwiftUI

/// Discover-hub — bundelt de drie ontdek-surfaces op één logische plek:
///   - Bibliotheek   — DiscoveryView (eigen collectie herontdekken: Album van de Dag, nooit gehoord, vergeten parels, grafieken)
///   - Wekelijks     — DiscoverWeeklyView (wekelijkse gepersonaliseerde 30-track mix)
///   - Nieuwe Muziek — DiscoverFeedView (aanbevelingen buiten de bibliotheek via streaming/Qobuz/MusicBrainz)
///
/// Brengt rust en overzicht in de navigatie door de voorheen versnipperde
/// "Ontdekken" / "Ontdekkingen" / "Wekelijks" schermen samen te voegen.
@MainActor
public struct DiscoverHubView: View {
    public init() {}

    public enum Mode: String, CaseIterable, Identifiable {
        case library, weekly, newMusic
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .library:  LS("nav.discovery")
            case .weekly:   LS("root.discoverWeekly")
            case .newMusic: LS("nav.discover")
            }
        }
    }

    @State private var mode: Mode = .library

    public var body: some View {
        VStack(spacing: 0) {
            Picker(LS("section.explore"), selection: $mode) {
                ForEach(Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch mode {
            case .library:  DiscoveryView()
            case .weekly:   DiscoverWeeklyView()
            case .newMusic: DiscoverFeedView()
            }
        }
    }
}
