import SwiftUI
import RoonSageCore
#if canImport(UIKit)
import UIKit
#endif

/// Immersive Now Playing: the selected zone is the showpiece — full-bleed
/// blurred-art backdrop, large springy album art, generous scrubber and gold
/// transport — with a compact switcher strip for the other zones. The old
/// version was a uniform list of small zone cards; a music app's marquee
/// screen deserves more than a 56-pt thumbnail.
public struct NowPlayingView: View {
    public init() {}
    @Environment(RoonClient.self) private var client

    public var body: some View {
        if client.localOutputSelected {
            // Listening on this device. Keyed on the CHOSEN output, not on
            // `localPlayback.isEngaged`: picking a Roon zone must switch this
            // screen to that zone even while local audio keeps playing in the
            // background (reachable again via the output picker → "dit
            // apparaat"). Otherwise a lingering local session made the zone
            // picker look dead.
            PlayerScreen(surface: LocalNowPlayingSurface(client: client))
        } else if client.zones.isEmpty {
            ContentUnavailableView(
                LS("nowPlaying.noActiveZones"),
                systemImage: "speaker.slash",
                description: LT("nowPlaying.startPlaybackHint")
            )
        } else if let zone = client.selectedZone {
            PlayerScreen(surface: ZoneNowPlayingSurface(client: client, zone: zone))
        } else {
            // Zones exist but none is selected yet (transient on launch/reconnect,
            // before RootView restores the last-used zone). Don't show a blank
            // screen — offer the zones explicitly.
            ContentUnavailableView {
                Label(LS("nowPlaying.chooseZone"), systemImage: "hifi.speaker")
            } description: {
                LT("nowPlaying.selectZoneHint")
            } actions: {
                ForEach(client.zones) { zone in
                    Button {
                        client.selectZone(zone.id)
                        Haptics.tap()
                    } label: {
                        Label(zone.displayName,
                              systemImage: zone.state == .playing ? "speaker.wave.2.fill" : "hifi.speaker")
                    }
                }
            }
        }
    }
}

// MARK: - Shared playback-option helpers

/// Loop-mode labels for the Queue toolbar and the command palette.
///
/// The cycling itself moved to `NowPlayingModel.nextLoop` in Core, where it is
/// covered by tests; this stays as the label side, which needs the string
/// catalogue and therefore has to live in this target.
enum NowPlayingHeroOptions {
    /// Cycle Roon's loop setting: off → all → one → off.
    static func nextLoop(_ current: String) -> String { NowPlayingModel.nextLoop(current) }

    static func loopLabel(_ loop: String) -> String {
        switch loop {
        case "loop":     LS("nowPlaying.repeatAll")
        case "loop_one": LS("nowPlaying.repeatOne")
        default:         LS("nowPlaying.repeatOff")
        }
    }

    // `attributeBadges` lived here: compact mood labels derived from the CLAP
    // attribute axes. Removed with its last call site when the zone badge row was
    // trimmed to BPM + key (the local player dropped it earlier for the same
    // reason). The mood axes are still shown in Sonic DNA, which reads them from
    // `attributesFor` directly. Recoverable with
    // `git show v1.10.259 -- native/RoonSage/Sources/RoonSageUI/NowPlayingView.swift`.
}

// MARK: - Output switcher

/// The list of places the music can come out, shared by every picker in the app.
///
/// There were three copies of this menu — the Now Playing pill, the toolbar
/// picker in `RootView`, and the one in `AIComponents` — and they had already
/// drifted: each built its own icon logic, and all three put "dit apparaat"
/// BELOW a divider, after the Roon zones. That framing is left over from when
/// on-device playback was the exception you switched out of; it has been the
/// default output since v1.10.228. One list, this device first, no divider —
/// they're all just destinations.
@MainActor
struct OutputMenuContent: View {
    @Environment(RoonClient.self) private var client
    @AppStorage("lastZoneID") private var lastZoneID: String = ""

    var body: some View {
        let localOn = client.localOutputSelected
        let active = client.selectedZone

        Button {
            client.selectLocalOutput(); Haptics.tap()
        } label: {
            Label(localOutputLabel,
                  systemImage: localOn ? "checkmark" : RoonClient.localOutputIcon)
        }

        ForEach(client.zones) { zone in
            Button {
                client.selectZone(zone.id); lastZoneID = zone.id; Haptics.tap()
            } label: {
                Label(zone.displayName,
                      systemImage: (!localOn && zone.id == active?.id) ? "checkmark"
                          : (zone.state == .playing ? "speaker.wave.2.fill" : "hifi.speaker"))
            }
        }
    }

    /// The icon for whatever is currently selected — same logic for every label
    /// that shows the active output, so they can't disagree.
    @MainActor
    static func activeIcon(_ client: RoonClient) -> String {
        if client.localOutputSelected { return RoonClient.localOutputIcon }
        return client.selectedZone?.state == .playing ? "speaker.wave.2.fill" : "hifi.speaker"
    }

    @MainActor
    static func activeName(_ client: RoonClient, fallback: String) -> String {
        if client.localOutputSelected { return localOutputLabel }
        return client.selectedZone?.displayName ?? fallback
    }
}

/// One pill for "where does this come out": the destination menu, and — only
/// while this device is the output — the system AirPlay picker beside it,
/// inside the same capsule.
///
/// They used to be two separate controls sitting next to each other, which read
/// as two unrelated decisions. They aren't: AirPlay is where THIS device sends
/// its audio, so it belongs in the same pill as the choice of device.
///
/// The AirPlay targets themselves can't join the menu above. `AVRoutePickerView`
/// presents the system sheet itself and there is no public API to enumerate
/// routes or to trigger the picker, so the real view has to be on screen and
/// keeps its own hit target. Reaching into its view hierarchy to fake a tap
/// would work today and break silently on some future OS — not worth it for one
/// less divider.
@MainActor
struct OutputSelector: View {
    @Environment(RoonClient.self) private var client

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                OutputMenuContent()
            } label: {
                HStack(spacing: Spacing.xs + 2) {
                    Image(systemName: OutputMenuContent.activeIcon(client))
                        .font(.caption)
                    Text(OutputMenuContent.activeName(client, fallback: LS("nowPlaying.chooseOutput")))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .opacity(0.7)
                }
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs + 2)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Output: \(OutputMenuContent.activeName(client, fallback: LS("nowPlaying.none")))")
            .accessibilityHint(LS("nowPlaying.chooseOutputHint"))

            if client.localOutputSelected {
                Divider().frame(height: 18).opacity(0.4)
                AirPlayRouteButton()
                    .padding(.horizontal, Spacing.xs)
            }
        }
        .background(.quaternary, in: Capsule())
        .foregroundStyle(.primary)
    }
}

// MARK: - Full-screen artwork (tap the hero art)

@MainActor
struct FullArtworkView: View {
    @Environment(\.dismiss) private var dismiss
    let url: URL?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let url {
                CachedArtImage(url: url) {
                    ProgressView().controlSize(.large)
                }
                .aspectRatio(1, contentMode: .fit)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Image(systemName: "music.note")
                    .font(.system(size: 72)).foregroundStyle(.secondary)
            }
            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                    .padding()
                    .accessibilityLabel(LS("nowPlaying.close"))
                }
                Spacer()
            }
        }
        .onTapGesture { dismiss() }
        #if os(macOS)
        .frame(minWidth: 600, minHeight: 600)
        #endif
    }
}
