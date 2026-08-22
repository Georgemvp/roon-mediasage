import RoonSageCore
import SwiftUI

/// The two **finite** journeys:
///   • Time Machine — a chronological journey old → new through your library
///   • The Bridge   — an A→B path between two tracks (reuses Song Paths)
///
/// Album Radio used to sit here as a third card, and that was a category error:
/// it never ends. A screen that presents "endless" and "has a last track" as
/// three equal cards teaches you nothing about which is which. It moved to the
/// stations, where everything else that runs forever lives.
///
/// **One card shape for all three.** They used to be three different things:
/// Album Radio was a block of text with no action at all, Time Machine had a
/// stepper and two inline buttons, The Bridge was a `NavigationLink` with a
/// hand-drawn chevron next to the one `List` already draws. Three journeys, three
/// interaction models, on a screen whose whole promise is that they are variants
/// of one idea. `journeyCard` gives each of them an icon, a name, one line of
/// explanation and exactly one primary action.
@MainActor
public struct SonicJourneysView: View {
    @Environment(RoonClient.self) private var client

    @State private var count = 40
    @State private var building = false
    @State private var syncing = false
    @State private var message: String?
    @State private var showBridge = false

    public init() {}

    public var body: some View {
        List {
            ZoneHintBanner().plainCardRow()
            timeMachineCard.plainCardRow()
            bridgeCard.plainCardRow()
        }
        .cardFeedList()
        .navigationDestination(isPresented: $showBridge) { SongPathsView() }
        .screenTitle(LS("nav.journeys"))
    }

    // MARK: - Shared card shape

    /// Icon + name + one line, then whatever the journey needs to start.
    @ViewBuilder
    private func journeyCard<Controls: View>(
        icon: String, title: String, blurb: String,
        @ViewBuilder controls: () -> Controls
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.md) {
                Image(systemName: icon)
                    .font(.title3)
                    .foregroundStyle(Color.roonGold)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(blurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            controls()
        }
        .cardStyle()
    }

    // MARK: - Time Machine

    private var timeMachineCard: some View {
        journeyCard(icon: "clock.arrow.circlepath",
                    title: LS("sonicJourneys.timeMachine"),
                    blurb: LS("sonicJourneys.timeMachineDesc")) {
            Stepper(value: $count, in: 20...80, step: 10) {
                Text(String(format: LS("sonicJourneys.length"), count))
                    .font(.subheadline)
            }

            Button {
                startTimeMachine()
            } label: {
                Label(building ? LS("sonicJourneys.building") : LS("sonicJourneys.startJourney"),
                      systemImage: "play.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.roonGold)
            // `hasActiveOutput`, not `selectedZone`: this button was dead on the
            // one output the app defaults to since v1.10.228 — your own phone.
            .disabled(building || !client.hasActiveOutput)

            if client.qobuzConfigured {
                Button {
                    syncTimeMachine()
                } label: {
                    Label(syncing ? LS("sonicJourneys.syncing") : LS("sonicJourneys.syncToQobuz"),
                          systemImage: "arrow.triangle.2.circlepath")
                        .labelStyle(.titleAndIcon)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(syncing)
            }

            // A disabled button with no reason next to it reads as a bug.
            if !client.hasActiveOutput {
                Text(LS("sonicJourneys.needOutput"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func startTimeMachine() {
        Haptics.tap()
        Task {
            building = true
            defer { building = false }
            let tracks = await client.buildTimeMachine(count: count)
            guard !tracks.isEmpty else {
                message = LS("sonicJourneys.noYearTracks")
                return
            }
            await client.playToActiveOutput(tracks)
            message = String(format: LS("sonicJourneys.started"), tracks.count)
        }
    }

    private func syncTimeMachine() {
        Haptics.tap()
        Task {
            syncing = true
            defer { syncing = false }
            let tracks = await client.buildTimeMachine(count: count)
            guard !tracks.isEmpty else {
                message = LS("sonicJourneys.noYearTracksSync")
                return
            }
            let ok = await client.syncJourneyToQobuz(
                title: "Time Machine",
                description: LS("sonicJourneys.qobuzDescription"),
                tracks: tracks)
            message = ok
                ? String(format: LS("sonicJourneys.qobuzSynced"),
                         RoonClient.qobuzPlaylistName(for: "Time Machine"))
                : LS("sonicJourneys.qobuzSyncFailed")
        }
    }

    // MARK: - The Bridge

    /// A `Button` + `navigationDestination`, not a `NavigationLink`.
    ///
    /// Inside a `List` a NavigationLink insists on drawing the row's own
    /// disclosure chevron and ignores `.buttonStyle(.bordered)` on its label, so
    /// this card's action rendered as bare text with a stray "›" next to it while
    /// the two cards above it had proper buttons. Driving the push ourselves is
    /// the only way to make all three look like one screen.
    private var bridgeCard: some View {
        journeyCard(icon: "point.topleft.down.curvedto.point.bottomright.up",
                    title: LS("sonicJourneys.bridge"),
                    blurb: LS("sonicJourneys.bridgeDesc")) {
            Button {
                Haptics.tap()
                showBridge = true
            } label: {
                Label(LS("sonicJourneys.pickTwoTracks"), systemImage: "arrow.right")
                    .labelStyle(.titleAndIcon)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
    }
}
