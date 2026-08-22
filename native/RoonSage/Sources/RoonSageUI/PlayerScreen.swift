import SwiftUI
import RoonSageCore
#if canImport(UIKit)
import UIKit
#endif

/// The one full-screen player, for every output.
///
/// It replaces `LocalNowPlayingScreen` and `NowPlayingHero`, which drew the same
/// screen from two sets of bindings. Where they differed it was almost never on
/// purpose: the local player had haptics on ⏮ and the zone didn't, the zone had
/// an accessibility scrub action and the local player didn't, the local player
/// dead-ended on "nothing playing" while the zone offered a way out. Those are
/// merged to the better of the two here rather than carried forward twice.
///
/// What genuinely differs per output is asked of the surface — see
/// `NowPlayingSurface`.
/// How this screen reaches the queue.
///
/// On the phone the player is a sheet whose second page IS the queue, so the
/// button pages sideways; presenting yet another sheet on top of a sheet would
/// be a worse version of a gesture that already exists. In the macOS/iPad split
/// view there is no paging, so the button falls back to presenting the queue
/// itself. Nil means "no pager here — use the sheet".
struct ShowQueueKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}

extension EnvironmentValues {
    var showQueue: (@MainActor () -> Void)? {
        get { self[ShowQueueKey.self] }
        set { self[ShowQueueKey.self] = newValue }
    }
}

@MainActor
struct PlayerScreen: View {
    let surface: any NowPlayingSurface

    var body: some View {
        ZStack {
            PlayerBackdrop(imageKey: surface.imageKey)
            VStack(spacing: 0) {
                // iOS hides the nav bar on this screen, so the body carries the
                // output switcher. A Menu (not a scrolling strip) never clips and
                // is immune to window/scene resizing. On macOS the toolbar
                // already provides the picker, so no in-body duplicate.
                #if os(iOS)
                HStack(spacing: Spacing.xs) {
                    OutputSelector()
                    AirPlayRouteButton()
                }
                // Room for the sheet's drag indicator: on the phone this screen
                // is presented as a card you pull down, and the grabber is drawn
                // over the top of the content. 8pt put the output pill right
                // under it.
                .padding(.top, Spacing.lg)
                .padding(.bottom, Spacing.xs)
                #endif
                PlayerHero(surface: surface)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Immersive media screen: always light foreground over the darkened art,
        // regardless of the app's light/dark theme — a light theme would
        // otherwise render black controls invisible on the scrim.
        .environment(\.colorScheme, .dark)
        // Meaningful bar title: the playing track, or where you're listening
        // when nothing is — not the redundant "Nu speelt" (the tab bar already
        // labels this).
        .navigationTitle(surface.title ?? surface.idleSubtitle ?? localOutputLabel)
        // Swapping output starts a fresh screen, the way moving between two
        // separate views used to: no stale scrubber anchor or volume level
        // carried over from the output you just left.
        .id(surface.surfaceID)
    }
}

// MARK: - Backdrop

/// Full-bleed backdrop: the album art, heavily blurred and dimmed behind a
/// material so foreground text stays legible in light and dark mode, with a
/// subtle tint from the art's dominant colour. Cross-fades on track change.
@MainActor
struct PlayerBackdrop: View {
    @Environment(RoonClient.self) private var client
    let imageKey: String?
    @State private var artColor: Color?

    var body: some View {
        ZStack {
            if let imageKey, let url = client.imageURL(forKey: imageKey, size: 300) {
                CachedArtImage(url: url) { Color.clear }
                    .id(imageKey)
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    .blur(radius: 60, opaque: true)
                    .transition(.opacity)
            }
            Rectangle().fill(.regularMaterial)
            if let artColor {
                LinearGradient(
                    colors: [artColor.opacity(0.35), artColor.opacity(0.05), .clear],
                    startPoint: .top, endPoint: .bottom
                )
            }
            // Dark scrim so the white foreground always has contrast — a bright
            // album cover would otherwise wash it all out. Heaviest toward the
            // bottom, where the controls sit; the artwork up top stays vibrant.
            LinearGradient(
                colors: [.black.opacity(0.15), .black.opacity(0.35), .black.opacity(0.7)],
                startPoint: .top, endPoint: .bottom
            )
        }
        .ignoresSafeArea()
        .animation(Motion.ambient, value: artColor)
        .task(id: imageKey) {
            guard let imageKey, let url = client.imageURL(forKey: imageKey, size: 64) else {
                artColor = nil; return
            }
            artColor = await ImageCache.shared.dominantColor(for: url)
        }
    }
}

// MARK: - Hero

@MainActor
private struct PlayerHero: View {
    @Environment(RoonClient.self) private var client
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.navigateTo) private var navigateTo
    let surface: any NowPlayingSurface

    /// Seed from the surface so the very first frame shows the real position and
    /// volume — no flash from 0:00 / 0, and it renders correctly off-screen too
    /// (the wall display and share cards draw this view without presenting it).
    init(surface: any NowPlayingSurface) {
        self.surface = surface
        _volumeValue = State(initialValue: surface.volume?.value ?? 0)
    }

    @State private var volumeValue: Double = 0

    @State private var feat: (bpm: Double, camelot: String, tags: [String])?
    @State private var attrs: [String: Float] = [:]
    @State private var startingRadio = false
    @State private var startingAdventure = false
    @State private var showLyrics = false
    @State private var showFullArt = false
    @State private var showWall = false
    @State private var showQueueSheet = false
    @State private var similarSeed: SonicSeed?
    @Environment(\.showQueue) private var pageToQueue
    @AppStorage("showVisualizer") private var showVisualizer = true

    /// The real width to bound the hero to. On iOS we read the active window's
    /// width directly (capped for iPad) instead of trusting the layout proposal,
    /// which iOS 26.6 inflates beyond the screen for hidden-bar NavigationStack
    /// content — ~560pt on a 390pt iPhone. Neither a greedy GeometryReader (it
    /// READS 560) nor `.frame(maxWidth: .infinity)` (it CLAMPS to 560) can keep
    /// the content on screen. On macOS the window is correctly sized, so a plain
    /// cap suffices.
    private var maxContentWidth: CGFloat {
        #if canImport(UIKit)
        let windowWidth = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow?.bounds.width }
            .first ?? UIScreen.main.bounds.width
        return min(windowWidth > 0 ? windowWidth : 560, 560)
        #else
        return 560
        #endif
    }

    var body: some View {
        VStack(spacing: Spacing.md) {
            Spacer(minLength: 0)
            art
            Spacer(minLength: 0)
            trackInfo
            featureRow
            visualizer
            scrubber
            transport
            volumeRow
            footerRow
            if let err = surface.errorMessage { errorLine(err) }
            if let note = surface.statusNote { statusLine(note) }
        }
        .padding(.horizontal, Spacing.xl)
        .frame(width: maxContentWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, Spacing.sm)
        .task(id: surface.featureKey) { await refreshFeatures() }
        .task { await client.ensureFeedbackLoaded() }
        .onChange(of: surface.volume?.value) { _, v in if let v, !isAdjustingVolume { volumeValue = v } }
        .sheet(isPresented: $showLyrics) { lyricsSheet }
        .sheet(isPresented: $showWall) { WallDisplayView() }
        .sheet(isPresented: $showQueueSheet) {
            NavigationStack { QueueView().navigationTitle(LS("nav.queue")) }
        }
        .similarTracksSheet(item: $similarSeed)
    }

    @ViewBuilder
    private var lyricsSheet: some View {
        switch surface.lyricsSource {
        case .zone(let z): LyricsView(zone: z)
        case .device:      LyricsView()
        }
    }

    // MARK: Art — sized to fit; springs on track change, shrinks slightly when paused

    private var art: some View {
        ZStack {
            if let key = surface.imageKey, let url = client.imageURL(forKey: key, size: 600) {
                CachedArtImage(url: url) { artPlaceholder }
                    .id(key)   // new art transitions in instead of mutating in place
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94)))
            } else {
                artPlaceholder
            }
        }
        // Square, capped for large screens, and free to SHRINK to the space left
        // after the controls — no fixed size, so no GeometryReader is needed.
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 420, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Radius.xl))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
        .scaleEffect(surface.isPlaying || reduceMotion ? 1.0 : 0.96)
        .animation(reduceMotion ? nil : Motion.spring, value: surface.isPlaying)
        .animation(reduceMotion ? nil : Motion.spring, value: surface.imageKey)
        .onTapGesture { if surface.imageKey != nil { showFullArt = true } }
        .sheet(isPresented: $showFullArt) {
            FullArtworkView(url: surface.imageKey.flatMap { client.imageURL(forKey: $0, size: 1200) })
        }
        .accessibilityHidden(true)
    }

    private var artPlaceholder: some View {
        RoundedRectangle(cornerRadius: Radius.xl)
            .fill(.quaternary)
            .overlay(
                Image(systemName: "music.note")
                    .font(.system(size: 56))
                    .foregroundStyle(.tertiary)
            )
    }

    // MARK: Track info

    @ViewBuilder
    private var trackInfo: some View {
        VStack(spacing: Spacing.xs) {
            if let title = surface.title {
                // One scrolling line, not two: the title is what runs long
                // (classical movements especially), and a second moving line
                // turns the screen into a ticker tape.
                MarqueeText(text: title.displayTitle, font: .title2.bold())
                if let artist = surface.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let album = surface.album, !album.isEmpty {
                    Text(album)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            } else {
                LT("nowPlaying.nothingPlaying")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                if let sub = surface.idleSubtitle {
                    Text(sub)
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                }
                // A discovery app shouldn't dead-end here — offer a way to start.
                // The local player used to, which made an idle phone look broken.
                HStack(spacing: Spacing.sm) {
                    Button {
                        Haptics.tap(); navigateTo(.discovery)
                    } label: {
                        Label(LS("nowPlaying.discoverMusic"), systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        Haptics.tap(); navigateTo(.generate)
                    } label: {
                        Label(LS("nowPlaying.makePlaylist"), systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.bordered)
                }
                .font(.callout)
                .padding(.top, Spacing.md)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Audio features — only the two badges that read at a glance and are
    // act-on-able while listening. This row used to carry BPM, key, two mood
    // tags, every CLAP attribute badge AND two buttons in one `lineLimit(1)`
    // HStack, which truncated into a row of unreadable stubs on a phone. The
    // tags and attributes live on in Sonic DNA, which is where you go to look
    // at them.

    @ViewBuilder
    private var featureRow: some View {
        if surface.hasTrack, feat != nil || surface.isDownloaded {
            HStack(spacing: Spacing.sm) {
                if let f = feat {
                    if f.bpm > 0 { Badge("\(Int(f.bpm)) BPM", tint: .roonGold) }
                    if !f.camelot.isEmpty { Badge(f.camelot, tint: .roonGold) }
                }
                // The one thing a portable player should say out loud: this
                // track is on the device, so it keeps playing without a network.
                // The library rows have carried this mark since the downloads
                // landed; the player — where you'd actually wonder — didn't.
                if surface.isDownloaded {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(Color.roonGold)
                        .accessibilityLabel(LS("downloads.availableOffline"))
                }
            }
            .lineLimit(1)
        }
    }

    // MARK: Visualizer — beat-driven equalizer fed by the analyzer's BPM/energy/
    // valence (no audio tap needed, so it works for a Roon zone too). Opt-out
    // via Settings → Verschijning.

    @ViewBuilder
    private var visualizer: some View {
        if showVisualizer, surface.hasTrack, let f = feat, f.bpm > 0 {
            BeatVisualizer(
                bpm: f.bpm,
                intensity: Double(attrs["danceability"] ?? attrs["energy"] ?? 0.55),
                warmth: Double(attrs["valence"] ?? 0.5),
                isPlaying: surface.isPlaying,
                reduceMotion: reduceMotion
            )
            .padding(.horizontal, Spacing.sm)
            .transition(.opacity)
        }
    }

    // MARK: Scrubber

    /// The progress bar, as its own view — the whole point of this split.
    ///
    /// `displayPosition` used to be `@State` on the hero, ticked once a second,
    /// and the scrubber read it. So every tick invalidated the ENTIRE hero: the
    /// artwork, the marquee title, the feature badges, the visualizer, the
    /// transport, the volume row and the footer, sixty times a minute, to move a
    /// six-point bar. Owning the clock here means a tick invalidates the bar and
    /// nothing else.
    private var scrubber: some View {
        PlayerScrubber(
            positionSec: surface.positionSec,
            durationSec: surface.durationSec,
            isPlaying: surface.isPlaying,
            positionIsContinuous: surface.positionIsContinuous,
            queueSummary: surface.queueSummary,
            onSeek: { surface.seek(toSeconds: $0) }
        )
    }

    // MARK: Transport

    /// Shuffle and repeat flank the transport instead of living on their own
    /// row: they ARE playback controls, and folding them in removes a whole
    /// strip of icons from the screen.
    private var transport: some View {
        HStack(spacing: Spacing.xl) {
            Button {
                Haptics.tap(); surface.setShuffle(!surface.shuffle)
            } label: {
                Image(systemName: "shuffle")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(surface.shuffle ? Color.roonGold : .secondary)
                    .tappable44()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(LS("queue.shuffle"))
            .accessibilityValue(surface.shuffle ? LS("nowPlaying.on") : LS("nowPlaying.off"))
            .accessibilityAddTraits(surface.shuffle ? .isSelected : [])

            Button {
                Haptics.tap(); surface.previous()
            } label: {
                Image(systemName: "backward.fill").font(.title)
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(LS("nowPlaying.previousTrack"))

            Button {
                Haptics.tap(); surface.toggle()
            } label: {
                Image(systemName: surface.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(Color.roonGold)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(surface.isPlaying ? LS("nowPlaying.pause") : LS("nowPlaying.play"))

            Button {
                Haptics.tap(); surface.next()
            } label: {
                Image(systemName: "forward.fill").font(.title)
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(LS("nowPlaying.nextTrack"))

            Button {
                Haptics.tap(); surface.setLoop(NowPlayingModel.nextLoop(surface.loopMode))
            } label: {
                Image(systemName: surface.loopMode == "loop_one" ? "repeat.1" : "repeat")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(surface.loopMode == "disabled" ? .secondary : Color.roonGold)
                    .tappable44()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NowPlayingHeroOptions.loopLabel(surface.loopMode))
            .accessibilityAddTraits(surface.loopMode == "disabled" ? [] : .isSelected)
        }
    }

    // MARK: Volume

    /// Whether the slider is under the finger — a poll landing mid-drag must not
    /// yank the knob back to the server's last known level.
    @State private var isAdjustingVolume = false
    /// When the last live level went out, so a drag doesn't flood the zone.
    @State private var lastVolumeSentAt = Date.distantPast

    /// A volume slider that only commits on release is a picture of a volume
    /// control, not a volume control: you drag, the knob moves, and the room
    /// stays exactly as loud as it was until you let go. Every hardware remote
    /// and every other player changes the level as you move.
    ///
    /// Throttled rather than debounced. A trailing debounce would send nothing
    /// at all while the finger keeps moving — which is the behaviour being fixed
    /// — so this sends the leading value and then at most one every 150 ms. The
    /// release still sends the final value unconditionally, so where the knob
    /// stops is always where the zone ends up, even if the last tick was
    /// throttled away.
    private static let liveVolumeInterval: TimeInterval = 0.15

    private func sendLiveVolume(_ value: Double, _ vol: PlayerVolume) {
        guard isAdjustingVolume else { return }
        let now = Date()
        guard now.timeIntervalSince(lastVolumeSentAt) >= Self.liveVolumeInterval else { return }
        lastVolumeSentAt = now
        vol.set(value)
    }

    @ViewBuilder
    private var volumeRow: some View {
        if surface.usesSystemVolume {
            // On the phone an app-level slider is a lie: it attenuates on top of
            // the device volume, so the hardware buttons and Control Center
            // disagree with what the app shows. `MPVolumeView` is the real thing.
            HStack(spacing: Spacing.sm) {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                SystemVolumeSlider()
            }
        } else if let vol = surface.volume {
            HStack(spacing: Spacing.sm) {
                Button {
                    Haptics.tap(); vol.toggleMute()
                } label: {
                    Image(systemName: vol.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .foregroundStyle(.secondary)
                        .tappable44()
                }
                .buttonStyle(.plain)
                .accessibilityLabel(vol.isMuted ? LS("nowPlaying.unmute") : LS("nowPlaying.mute"))

                Slider(value: $volumeValue, in: vol.range, step: vol.step) { editing in
                    isAdjustingVolume = editing
                    // The release always commits, throttle or no throttle.
                    if !editing { lastVolumeSentAt = .distantPast; vol.set(volumeValue) }
                }
                .onChange(of: volumeValue) { _, v in sendLiveVolume(v, vol) }
                // Neutral tint (not gold) so the volume reads as a separate
                // control and isn't mistaken for a second progress bar.
                .tint(.white.opacity(0.55))
                .controlSize(.small)
                .accessibilityLabel(LS("nowPlaying.volume"))

                Text("\(vol.isMuted ? 0 : Int(volumeValue.rounded()))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(width: 28, alignment: .trailing)
            }
        }
    }

    // MARK: Footer — like/dislike (teaches radios & recommendations) + up-next

    @ViewBuilder
    private var footerRow: some View {
        if let title = surface.title {
            let artist = surface.artist
            let album = surface.album
            let current = client.feedbackFor(title: title, artist: artist, album: album)
            HStack(spacing: Spacing.lg) {
                Button {
                    Haptics.tap()
                    Task { await client.setFeedback(.like, title: title, artist: artist, album: album) }
                } label: {
                    Image(systemName: current == .like ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .font(.title3)
                        .foregroundStyle(current == .like ? Color.roonGold : .primary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LS("nowPlaying.like"))
                .accessibilityAddTraits(current == .like ? .isSelected : [])

                Button {
                    Haptics.tap()
                    Task { await client.setFeedback(.dislike, title: title, artist: artist, album: album) }
                } label: {
                    Image(systemName: current == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .font(.title3)
                        .foregroundStyle(current == .dislike ? Color.roonDanger : .primary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LS("nowPlaying.dislike"))
                .accessibilityAddTraits(current == .dislike ? .isSelected : [])

                Button {
                    Haptics.tap(); showLyrics = true
                } label: {
                    Image(systemName: "quote.bubble")
                        .font(.title3)
                        .foregroundStyle(.primary)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LS("nowPlaying.lyrics"))

                // The queue had no handle at all: on the phone it was one
                // undiscoverable sideways swipe, and the page dots that would
                // have advertised it were removed because they swallowed taps
                // meant for the buttons right here. A button says it out loud.
                Button {
                    Haptics.tap()
                    if let pageToQueue { pageToQueue() } else { showQueueSheet = true }
                } label: {
                    Image(systemName: "list.bullet")
                        .font(.title3)
                        .foregroundStyle(.primary)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LS("nav.queue"))
                .accessibilityValue(surface.queueSummary ?? "")

                // Everything you might want but rarely mid-song, behind one
                // glyph. Four icons on the screen became one; nothing was lost.
                overflowMenu(title: title, artist: artist, album: album)

                if let next = surface.upNext {
                    Spacer(minLength: Spacing.sm)
                    // Lower layout priority so a long "up next" title never
                    // squeezes the like/dislike buttons off the leading edge.
                    nextUpPill(next).layoutPriority(-1)
                } else {
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func overflowMenu(title: String, artist: String?, album: String?) -> some View {
        Menu {
            if surface.supportsSonicRadio {
                Button {
                    startingRadio = true
                    Task { await surface.startSonicRadio(); startingRadio = false }
                } label: {
                    Label("Sonic Radio", systemImage: "dot.radiowaves.left.and.right")
                }
                .disabled(startingRadio)
            }

            Button {
                startingAdventure = true
                Task { await surface.startJourney(); startingAdventure = false }
            } label: { Label(LS("nowPlaying.journey"), systemImage: "map") }
                .disabled(startingAdventure)

            Button {
                similarSeed = SonicSeed(title: title, artist: artist,
                                        album: album, imageKey: surface.imageKey)
            } label: {
                Label(LS("nowPlaying.sonicallySimilar"), systemImage: "waveform.path.ecg")
            }

            Button {
                showWall = true
            } label: { Label(LS("nowPlaying.wallDisplay"), systemImage: "play.tv") }

            ShareCardButton(title: title.displayTitle, artist: artist,
                            imageKey: surface.imageKey, inMenu: true)
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(.title3)
                .foregroundStyle(.primary)
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel(LS("nowPlaying.more"))
    }

    private func nextUpPill(_ next: PlayerUpNext) -> some View {
        HStack(spacing: Spacing.sm) {
            VStack(alignment: .trailing, spacing: 1) {
                LT("nowPlaying.upNext").font(.caption2).foregroundStyle(.secondary)
                Text(next.title).font(.caption.weight(.medium)).lineLimit(1)
                if let s = next.subtitle, !s.isEmpty {
                    Text(s).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            AlbumArtView(imageKey: next.imageKey, size: 36)
            Image(systemName: "forward.end.fill")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { Haptics.tap(); surface.next() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(
            format: LS("nowPlaying.upNextAccessibility"),
            [next.title, next.subtitle].compactMap { $0 }.joined(separator: " — ")))
        .accessibilityHint(LS("nowPlaying.keepPlayingHint"))
    }

    // MARK: Error + status

    private func errorLine(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(Color.roonDanger)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: .infinity)
    }

    /// Just the "what got skipped" note. There is deliberately no stop button on
    /// this screen: a music player's marquee offers play/pause, not a destructive
    /// stop-and-wipe. Stopping is still reachable from the mini-player.
    ///
    /// This used to add "and the queue screen can clear what's upcoming", which
    /// is true for the on-device queue and false for a Roon zone — Roon's
    /// Extension API has no queue-mutation verb at all. `QueueView` now says so
    /// on the zone path instead of leaving you hunting for a button that cannot
    /// exist.
    private func statusLine(_ note: String) -> some View {
        Text(note)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }

    // MARK: Features

    private func refreshFeatures() async {
        guard let title = surface.title else {
            feat = nil; attrs = [:]; return
        }
        feat = await client.featuresFor(title: title, artist: surface.artist, album: surface.album)
        attrs = await client.attributesFor(title: title, artist: surface.artist, album: surface.album)
    }
}

// MARK: - Scrubber

/// Custom, bounded progress bar (the system Slider rendered full-bleed here).
/// Clear track, gold fill, draggable thumb, elapsed/remaining.
///
/// Owns the position clock so a tick redraws this and not the whole player.
@MainActor
struct PlayerScrubber: View {
    let positionSec: Double
    let durationSec: Double
    let isPlaying: Bool
    /// True for an engine that publishes a live position of its own; then there
    /// is nothing to interpolate and no ticker to run.
    let positionIsContinuous: Bool
    let queueSummary: String?
    let onSeek: (Double) -> Void

    init(positionSec: Double, durationSec: Double, isPlaying: Bool,
         positionIsContinuous: Bool, queueSummary: String?,
         onSeek: @escaping (Double) -> Void) {
        self.positionSec = positionSec
        self.durationSec = durationSec
        self.isPlaying = isPlaying
        self.positionIsContinuous = positionIsContinuous
        self.queueSummary = queueSummary
        self.onSeek = onSeek
        // Seed from the real position so the first frame is right — no flash
        // from 0:00, and it renders correctly off-screen too (the wall display
        // and the share cards draw this without presenting it).
        let pos = max(0, positionSec)
        _anchorPosition = State(initialValue: pos)
        _displayPosition = State(initialValue: pos)
    }

    // Position while dragging, in seconds. Held separately from the displayed
    // position so letting go can't be undone by a poll landing in the same frame.
    @State private var isSeeking = false
    @State private var seekPositionSec: Double = 0
    // For outputs that report a position per poll rather than continuously: the
    // last known-true position and when we learned it. See
    // `NowPlayingModel.interpolatedPosition`.
    @State private var anchorPosition: Double = 0
    @State private var anchorDate: Date = .init()
    @State private var displayPosition: Double = 0

    /// Whether the interpolating ticker should be running at all, and the key
    /// that restarts it. A paused zone has a position that by definition does not
    /// move, so ticking there wrote the same number into `@State` once a second
    /// forever — SwiftUI does not dedupe an equal `Double`, so a paused phone
    /// redrew at 1 Hz until the screen locked.
    private struct TickerKey: Equatable { let running: Bool }
    private var tickerKey: TickerKey {
        TickerKey(running: !positionIsContinuous && isPlaying)
    }

    /// The position to show right now: the finger while dragging, the engine's
    /// own clock when it has one, otherwise our interpolation.
    private var shownPosition: Double {
        if isSeeking { return seekPositionSec }
        return positionIsContinuous ? positionSec : displayPosition
    }

    /// Pin the displayed position to a known-true value and stamp the wall clock.
    private func setAnchor(_ pos: Double) {
        anchorPosition = max(0, pos)
        anchorDate = Date()
        displayPosition = anchorPosition
    }

    var body: some View {
        // Read the position UNCONDITIONALLY. Folding it into a ternary let Swift
        // short-circuit it whenever the duration was still 0, so SwiftUI never
        // registered a dependency and the row stopped redrawing entirely.
        let pos = shownPosition
        let dur = durationSec
        let frac = NowPlayingModel.fraction(position: pos, duration: dur)
        VStack(spacing: Spacing.xs) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.28)).frame(height: 6)
                    Capsule().fill(Color.roonGold).frame(width: max(0, w * frac), height: 6)
                    // Always show the knob (even at 0:00) so the bar clearly reads
                    // as a scrubber rather than a flat line.
                    Circle().fill(.white)
                        .frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .offset(x: min(max(w * frac - 8, 0), w - 16))
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                // High priority so a drag starting on the scrubber beats the paging
                // TabView that carries the queue one swipe away.
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            guard let s = NowPlayingModel.seekSeconds(
                                atX: v.location.x, width: w, duration: dur) else { return }
                            isSeeking = true
                            seekPositionSec = s
                        }
                        .onEnded { v in
                            guard let s = NowPlayingModel.seekSeconds(
                                atX: v.location.x, width: w, duration: dur) else {
                                isSeeking = false; return
                            }
                            seekPositionSec = s
                            setAnchor(s)          // hold until the next poll confirms
                            onSeek(s)
                            isSeeking = false
                        }
                )
            }
            .frame(height: 22)
            .accessibilityElement()
            .accessibilityLabel(LS("nowPlaying.playbackPosition"))
            .accessibilityValue(NowPlayingModel.formatTime(pos))
            .accessibilityHint(LS("nowPlaying.scrubHint"))
            .accessibilityAdjustableAction { direction in
                guard dur > 0 else { return }
                let step = dur * 0.05
                let target = direction == .increment ? min(pos + step, dur) : max(pos - step, 0)
                setAnchor(target)     // hold until the next poll confirms
                onSeek(target)
            }

            HStack {
                Text(NowPlayingModel.formatTime(pos))
                Spacer()
                // "3 van 24" between the two counters: it's positional
                // information, same as the clock, and this row already has the
                // space. A line of its own under the title would have made the
                // busiest part of the screen busier.
                if let queue = queueSummary {
                    Text(queue)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                }
                Text(NowPlayingModel.remainingLabel(position: pos, duration: dur))
            }
            .font(.footnote.weight(.medium).monospacedDigit())
            .foregroundStyle(.primary)
        }
        // Re-anchor on every authoritative update. Skipped entirely for an engine
        // that publishes a live position — writing state at 2 Hz to recompute a
        // number we already have is pure churn.
        .onChange(of: positionSec) { _, pos in
            guard !positionIsContinuous, !isSeeking else { return }
            setAnchor(pos)
        }
        // Pause/resume re-anchors at the frozen value, so resuming continues
        // where the bar stopped instead of jumping by the paused interval.
        .onChange(of: isPlaying) { _, _ in
            guard !positionIsContinuous else { return }
            setAnchor(displayPosition)
        }
        // A `.task`, not `Timer.publish(...).autoconnect()` inside `body`: that
        // built a NEW publisher on every body evaluation, and since the tick
        // itself caused an evaluation it re-subscribed a fresh timer every
        // second. This one starts when playback starts, stops when it stops, and
        // is cancelled for free when the view goes away.
        .task(id: tickerKey) {
            guard tickerKey.running else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled, !isSeeking else { continue }
                displayPosition = NowPlayingModel.interpolatedPosition(
                    anchor: anchorPosition, anchoredAt: anchorDate, now: Date(),
                    isPlaying: true, duration: durationSec)
            }
        }
    }
}
