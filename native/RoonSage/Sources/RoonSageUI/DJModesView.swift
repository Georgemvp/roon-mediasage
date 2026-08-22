import RoonSageCore
import SwiftUI

/// Guest-DJ personas — the Plexamp-style "Guest DJ" idea, renamed. Pick a persona
/// and it takes over what plays next from the track you're on (an endless station
/// seeded on the current track, shaped by that persona's dial/arc/gate). The
/// "Guest DJ · Autoplay" section makes one persona persistent: when normal
/// playback runs dry it's topped up automatically.
///
/// Built on `List` + `.plainCardRow()` like `SonicRadioView` (see `GenerateView`
/// for why not a custom ScrollView). Persona names/blurbs are English by design;
/// the surrounding chrome stays Dutch like the rest of the app.
@MainActor
public struct DJModesView: View {
    @Environment(RoonClient.self) private var client

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: Spacing.md)]

    public init() {}

    public var body: some View {
        @Bindable var client = client
        // Personas first. The autoplay block is a *setting* — it decides what
        // happens when the queue later runs dry — and it stood above the eight
        // cards that are the actual verb of this screen, which were greyed out
        // with their explanation stranded underneath it. Now: the reason you
        // can't start yet, then the personas, then the setting.
        List {
            if let radio = client.activeRadio { activeBanner(radio).plainCardRow() }

            ZoneHintBanner().plainCardRow()

            if !canStart {
                LT("dJModes.pickToSteer")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .plainCardRow()
            }

            LazyVGrid(columns: columns, spacing: Spacing.md) {
                ForEach(DJMode.allCases, id: \.self) { personaCard($0) }
            }
            .plainCardRow()

            autoplayCard.plainCardRow()
        }
        .cardFeedList()
        .screenTitle(LS("dJModes.title"))
    }

    // MARK: Sections


    /// Guest DJ · Autoplay — one persona keeps the queue topped up by itself.
    ///
    /// The two switches used to be bare `Toggle`s with `.caption` labels stacked
    /// at `Spacing.xs`; they rendered ON TOP of each other (see `SettingToggle`).
    private var autoplayCard: some View {
        @Bindable var client = client
        return VStack(alignment: .leading, spacing: Spacing.sm) {
            Label(LS("dJModes.autoplayTitle"), systemImage: "person.wave.2.fill")
                .font(.subheadline.weight(.semibold))
            LT("dJModes.autoplayDescription")
                .font(.caption)
                .foregroundStyle(.secondary)

            SettingToggle(LS("dJModes.autoplayToggle"), isOn: $client.djAutoplayEnabled)

            SettingToggle(LS("dJModes.autoPersonaToggle"), isOn: $client.djAutoplayAutoPersona)
                .disabled(!client.djAutoplayEnabled)

            HStack {
                LT("dJModes.autoplayPersonaLabel").font(.subheadline)
                Spacer()
                Picker(LS("dJModes.autoplayPersonaLabel"), selection: $client.selectedDJMode) {
                    ForEach(DJMode.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .disabled(client.djAutoplayAutoPersona)
            }
            Text(client.selectedDJMode.blurb)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .cardStyle()
    }

    private func activeBanner(_ radio: RoonClient.RadioStatus) -> some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.title3)
                .foregroundStyle(Color.roonGold)
            VStack(alignment: .leading, spacing: 2) {
                LT("dJModes.radioPlaying").font(.caption).foregroundStyle(.secondary)
                Text(radio.artist).font(.headline)
            }
            Spacer()
            Button(role: .destructive) {
                Haptics.tap()
                client.stopRadio()
            } label: {
                Label(LS("dJModes.stop"), systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
        }
        .cardStyle()
    }

    private func personaCard(_ mode: DJMode) -> some View {
        // Two things a persona can do, and until now only one was reachable:
        // take over from the track playing right now, OR steer every station you
        // start from here on (`stationPersona`). The second needs nothing to be
        // playing — which is why this grid used to be entirely dead on a quiet
        // app, with six greyed-out cards and a line telling you to go play
        // something first.
        Button {
            if canStart { start(mode) } else { useForStations(mode) }
        } label: {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack {
                    Image(systemName: mode.symbol)
                        .font(.title2)
                        .foregroundStyle(Color.roonGold)
                    Spacer()
                    Image(systemName: "play.circle.fill")
                        .font(.title3)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.roonGold)
                }
                Text(mode.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if client.stationPersona == mode {
                    Text(LS("stations.personaActive"))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Color.roonGold)
                }
                Text(mode.blurb)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.sm)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.lg))
            .contentShape(RoundedRectangle(cornerRadius: Radius.lg))
        }
        .buttonStyle(.plain)
        .contextMenu {
            if canStart {
                Button {
                    start(mode)
                } label: { Label(LS("dJModes.startFromCurrent"), systemImage: "play.fill") }
            }
            Button {
                useForStations(mode)
            } label: { Label(LS("stations.useForStations"), systemImage: "dot.radiowaves.left.and.right") }
        }
    }

    /// Make this persona steer every station start (see `RoonClient.stationPersona`).
    private func useForStations(_ mode: DJMode) {
        Haptics.tap()
        client.stationPersona = (client.stationPersona == mode) ? nil : mode
    }

    // MARK: Actions

    /// A persona starts on whatever is playing on the ACTIVE output — this
    /// device as readily as a zone.
    private var canStart: Bool { client.activeNowPlaying != nil }

    private func start(_ mode: DJMode) {
        guard let np = client.activeNowPlaying else { return }
        Haptics.tap()
        Task {
            await client.startTrackRadio(title: np.title, artist: np.artist,
                                         album: np.album, djMode: mode)
        }
    }
}
