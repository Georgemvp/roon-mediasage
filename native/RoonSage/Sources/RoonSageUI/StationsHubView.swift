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
/// **De kop hoort hier, één keer.** Elk van de vier schermen droeg zijn eigen
/// icoon + titel + ondertitel, en die titel was letterlijk de naam van het
/// segment één regel erboven — met de tabbalk erbij stond dezelfde naam drie keer
/// binnen 100 punten. Dat kostte 112 pt aan chrome voordat er inhoud kwam, op een
/// scherm waar de stations toch al onder de vouw begonnen. Nu: de kiezer zegt
/// waar je bent, één regel eronder zegt wat het is, en daarna komt inhoud.
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
            case .journeys: LS("stationsHub.journeys")
            case .generate: LS("nav.generate")
            }
        }

        /// One line, because the segment name alone doesn't say what "Journeys"
        /// or "Generate" will do. Deliberately short: it sits above everything
        /// else on the screen, so every word costs a station tile.
        var blurb: String {
            switch self {
            case .radios:   LS("stationsHub.radiosBlurb")
            case .djModes:  LS("stationsHub.djModesBlurb")
            case .journeys: LS("stationsHub.journeysBlurb")
            case .generate: LS("stationsHub.generateBlurb")
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
            .padding(.top, Spacing.sm)

            Text(mode.blurb)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.top, Spacing.xs)
                .padding(.bottom, Spacing.sm)
                .accessibilityAddTraits(.isHeader)

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
        // The tab already carries the name; a segment's child must not
        // rename it out from under us. See `ScreenTitle.swift`.
        .hubContent()
    }
}
