import RoonSageCore
import SwiftUI

/// Stations-hub — de drie eindeloze/zelf-sturende stations delen allemaal
/// `RadioEngine`: een DJ-persona is een radio met de avontuurlijkheids-dial + arc
/// voorgekookt, en Sonic Journeys zijn radio-vormige station-types. Voorheen drie
/// losse sidebar-items; hier samengevoegd tot één modus-schakelaar.
///   - Radio's  — SonicRadioView (dagelijkse for-you stations + dial)
///   - DJ-modi  — DJModesView (persona-presets over RadioEngine)
///   - Journeys — SonicJourneysView (Album Radio / Time Machine / The Bridge)
///   - Genereer — GenerateView (dezelfde vraag, maar met een eindige playlist
///                als antwoord in plaats van een eindeloos station)
///
/// De onderliggende views blijven ongewijzigd.
@MainActor
public struct StationsHubView: View {
    public init() {}

    enum Mode: String, CaseIterable, Identifiable {
        case radios, djModes, journeys, generate
        var id: String { rawValue }
        var label: String {
            switch self {
            case .radios:   LS("stationsHub.radios")
            case .djModes:  LS("stationsHub.djModes")
            case .journeys: "Journeys"
            case .generate: LS("nav.generate")
            }
        }
    }

    @State private var mode: Mode = .radios

    public var body: some View {
        VStack(spacing: 0) {
            Picker(LS("stationsHub.mode"), selection: $mode) {
                ForEach(Mode.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 8)

            switch mode {
            case .radios:   SonicRadioView()
            case .djModes:  DJModesView()
            case .journeys: SonicJourneysView()
            // "Genereer" belongs with the stations, not in a tab of its own: all
            // four answer "put something on for me", they only differ in whether
            // the result is endless or a finished playlist. It was behind
            // Maak → hub → segment; the "Maak" tab was a list that linked to a
            // hub, which is furniture, not a destination.
            case .generate: GenerateView()
            }
        }
    }
}
