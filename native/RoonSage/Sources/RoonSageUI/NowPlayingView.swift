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

/// Single dropdown pill for switching the playback output — every Roon zone plus
/// "dit apparaat" (on-device playback), so the local player is a first-class
/// output alongside the zones. A `Menu` (not a horizontal strip) can't clip a
/// chip and is unaffected by window/scene resizing. Shared by the zone hero and
/// the local Now Playing screen so the two never drift.
@MainActor
struct OutputSelector: View {
    @Environment(RoonClient.self) private var client
    @AppStorage("lastZoneID") private var lastZoneID: String = ""

    var body: some View {
        let localOn = client.localOutputSelected
        let active = client.selectedZone
        Menu {
            ForEach(client.zones) { zone in
                Button {
                    client.selectZone(zone.id); lastZoneID = zone.id; Haptics.tap()
                } label: {
                    Label(zone.displayName,
                          systemImage: (!localOn && zone.id == active?.id) ? "checkmark"
                              : (zone.state == .playing ? "speaker.wave.2.fill" : "hifi.speaker"))
                }
            }
            Divider()
            Button {
                client.selectLocalOutput(); Haptics.tap()
            } label: {
                Label(localOutputLabel,
                      systemImage: localOn ? "checkmark" : RoonClient.localOutputIcon)
            }
        } label: {
            HStack(spacing: Spacing.xs + 2) {
                Image(systemName: localOn ? RoonClient.localOutputIcon
                          : (active?.state == .playing ? "speaker.wave.2.fill" : "hifi.speaker"))
                    .font(.caption)
                Text(localOn ? localOutputLabel : (active?.displayName ?? LS("nowPlaying.chooseOutput")))
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.semibold))
                    .opacity(0.7)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs + 2)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Output: \(localOn ? localOutputLabel : (active?.displayName ?? LS("nowPlaying.none")))")
        .accessibilityHint(LS("nowPlaying.chooseOutputHint"))
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
