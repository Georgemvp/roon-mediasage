import SwiftUI
import RoonSageCore
#if canImport(UIKit)
import UIKit
#endif

/// Full-screen Now Playing surface for **on-device** ("dit apparaat" / "deze
/// Mac") playback, shown by `NowPlayingView` whenever the local engine is
/// engaged. It mirrors the Roon hero's visual language — blurred-art backdrop,
/// big springy art, gold transport — but binds every control to
/// `LocalPlaybackController` instead of a Roon zone, so playing here is finally
/// reflected and controlled from the marquee screen (not only the mini-player).
@MainActor
struct LocalNowPlayingScreen: View {
    @Environment(RoonClient.self) private var client

    var body: some View {
        let lp = client.localPlayback
        ZStack {
            LocalNowPlayingBackdrop(imageKey: lp.current?.imageKey)
            VStack(spacing: 0) {
                // Same output switcher as the zone hero, so you can hop back to a
                // Roon zone from the local screen. On macOS the toolbar carries it.
                #if os(iOS)
                HStack(spacing: Spacing.xs) {
                    OutputSelector()
                    AirPlayRouteButton()
                }
                .padding(.top, Spacing.sm)
                .padding(.bottom, Spacing.xs)
                #endif
                LocalNowPlayingHero()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        // Immersive media screen: always light foreground over the darkened art,
        // regardless of the app's light/dark theme (matches the Roon hero).
        .environment(\.colorScheme, .dark)
        .navigationTitle(lp.current?.title ?? Self.deviceNoun)
    }

    #if os(macOS)
    static let deviceNoun = LS("localNowPlaying.deviceNounMac")
    static let deviceIcon = "laptopcomputer"
    #else
    static let deviceNoun = LS("localNowPlaying.deviceNounDevice")
    static let deviceIcon = "iphone"
    #endif
}

// MARK: - Backdrop

@MainActor
private struct LocalNowPlayingBackdrop: View {
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
private struct LocalNowPlayingHero: View {
    @Environment(RoonClient.self) private var client
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSeeking = false
    @State private var seekFraction: Double = 0
    @State private var showFullArt = false
    @State private var showLyrics = false
    @State private var showWall = false
    @State private var similarSeed: SonicSeed?
    @State private var startingAdventure = false
    @State private var feat: (bpm: Double, camelot: String, tags: [String])?
    @State private var attrs: [String: Float] = [:]
    @State private var volumeValue: Double = 100
    @AppStorage("showVisualizer") private var showVisualizer = true

    /// Match the Roon hero's over-wide-region handling on iOS 26 (read the true
    /// window width, centre in the inflated proposal); a plain cap on macOS.
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
        let lp = client.localPlayback
        VStack(spacing: Spacing.md) {
            Spacer(minLength: 0)
            art(lp)
            Spacer(minLength: 0)
            trackInfo(lp)
            featureRow(lp)
            visualizer(lp)
            scrubber(lp)
            transport(lp)
            volumeRow(lp)
            feedbackRow(lp)
            if let err = lp.lastError { errorLine(err) }
            statusFooter(lp)
        }
        .padding(.horizontal, Spacing.xl)
        .frame(width: maxContentWidth)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, Spacing.sm)
        .onAppear { volumeValue = (lp.isMuted ? 0 : lp.volume) * 100 }
        .task(id: lp.current?.id) { await refreshFeatures(lp) }
        .onChange(of: lp.volume) { _, v in volumeValue = v * 100 }
        .onChange(of: lp.isMuted) { _, m in volumeValue = (m ? 0 : lp.volume) * 100 }
        .task { await client.ensureFeedbackLoaded() }
        .sheet(isPresented: $showLyrics) { LyricsView() }
        .sheet(isPresented: $showWall) { WallDisplayView() }
        .similarTracksSheet(item: $similarSeed)
    }

    // MARK: Art

    private func art(_ lp: LocalPlaybackController) -> some View {
        ZStack {
            if let key = lp.current?.imageKey, let url = client.imageURL(forKey: key, size: 600) {
                CachedArtImage(url: url) { artPlaceholder }
                    .id(key)
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.94)))
            } else {
                artPlaceholder
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 420, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: Radius.xl))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 12)
        .scaleEffect(lp.isPlaying || reduceMotion ? 1.0 : 0.96)
        .animation(reduceMotion ? nil : Motion.spring, value: lp.isPlaying)
        .animation(reduceMotion ? nil : Motion.spring, value: lp.current?.imageKey)
        .onTapGesture { if lp.current?.imageKey != nil { showFullArt = true } }
        .sheet(isPresented: $showFullArt) {
            FullArtworkView(url: lp.current?.imageKey.flatMap { client.imageURL(forKey: $0, size: 1200) })
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
    private func trackInfo(_ lp: LocalPlaybackController) -> some View {
        VStack(spacing: Spacing.xs) {
            if let track = lp.current {
                Text(track.title)
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if !track.artist.isEmpty {
                    Text(track.artist)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if !track.album.isEmpty {
                    Text(track.album)
                        .font(.subheadline)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            } else {
                LT("localNowPlaying.nothingPlaying").font(.title3).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Scrubber

    @ViewBuilder
    private func scrubber(_ lp: LocalPlaybackController) -> some View {
        // Read the position UNCONDITIONALLY. Folding it into the ternary below
        // meant Swift short-circuited it whenever the duration was still 0, so
        // SwiftUI never registered a dependency on it and the row stopped
        // redrawing entirely.
        let pos = lp.positionSec
        let dur = lp.durationSec
        let hasLength = dur > 0
        // While dragging, follow the finger; otherwise the engine's live position.
        let frac = isSeeking ? seekFraction : (hasLength ? min(max(pos / dur, 0), 1) : 0)
        // Without a known length the bar can't fill, but the elapsed counter can
        // still run — better than a frozen 0:00.
        let shownPos = hasLength ? frac * dur : pos
        VStack(spacing: Spacing.xs) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.28)).frame(height: 6)
                    Capsule().fill(Color.roonGold).frame(width: max(0, w * frac), height: 6)
                    Circle().fill(.white)
                        .frame(width: 16, height: 16)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                        .offset(x: min(max(w * frac - 8, 0), w - 16))
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { v in
                            guard hasLength, w > 0 else { return }
                            isSeeking = true
                            seekFraction = min(max(v.location.x / w, 0), 1)
                        }
                        .onEnded { v in
                            guard hasLength, w > 0 else { isSeeking = false; return }
                            let f = min(max(v.location.x / w, 0), 1)
                            lp.seek(toFraction: f)
                            isSeeking = false
                        }
                )
            }
            .frame(height: 22)
            .accessibilityElement()
            .accessibilityLabel(LS("localNowPlaying.playbackPosition"))
            .accessibilityValue(formatTime(shownPos))

            HStack {
                Text(formatTime(shownPos))
                Spacer()
                Text(hasLength ? "-" + formatTime(dur - shownPos) : "--:--")
            }
            .font(.footnote.weight(.medium).monospacedDigit())
            .foregroundStyle(.primary)
        }
    }

    // MARK: Transport

    /// Shuffle and repeat flank the transport instead of living on their own
    /// row: they ARE playback controls, and folding them in removes a whole
    /// strip of icons from the screen.
    private func transport(_ lp: LocalPlaybackController) -> some View {
        HStack(spacing: Spacing.xl) {
            Button { Haptics.tap(); lp.setShuffle(!lp.shuffle) } label: {
                Image(systemName: "shuffle")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(lp.shuffle ? Color.roonGold : .secondary)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Shuffle")
            .accessibilityValue(lp.shuffle ? LS("localNowPlaying.on") : LS("localNowPlaying.off"))
            .accessibilityAddTraits(lp.shuffle ? .isSelected : [])

            Button { Haptics.tap(); lp.previous() } label: {
                Image(systemName: "backward.fill").font(.title)
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(LS("localNowPlaying.previousTrack"))

            Button { Haptics.tap(); lp.togglePlayPause() } label: {
                Image(systemName: lp.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(Color.roonGold)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(lp.isPlaying ? LS("localNowPlaying.pause") : LS("localNowPlaying.play"))

            Button { Haptics.tap(); lp.next() } label: {
                Image(systemName: "forward.fill").font(.title)
            }
            .buttonStyle(.plain)
            .frame(minWidth: 44, minHeight: 44)
            .accessibilityLabel(LS("localNowPlaying.nextTrack"))

            Button { Haptics.tap(); lp.setLoop(NowPlayingHeroOptions.nextLoop(lp.loopMode)) } label: {
                Image(systemName: lp.loopMode == "loop_one" ? "repeat.1" : "repeat")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(lp.loopMode == "disabled" ? .secondary : Color.roonGold)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(NowPlayingHeroOptions.loopLabel(lp.loopMode))
            .accessibilityAddTraits(lp.loopMode == "disabled" ? [] : .isSelected)
        }
    }

    // MARK: Audio features (BPM / key / mood) — same badges as the zone hero,
    // read from the analyzer by the current track's title/artist/album.

    @ViewBuilder
    private func featureRow(_ lp: LocalPlaybackController) -> some View {
        if lp.current != nil, feat != nil || !attrs.isEmpty {
            // Only the two that read at a glance and are act-on-able while
            // listening. The genre text and the mood badges were three more
            // things competing for attention on the busiest strip of the screen;
            // they live on in Sonic DNA, where you go to look at them.
            HStack(spacing: Spacing.sm) {
                if let f = feat {
                    if f.bpm > 0 { Badge("\(Int(f.bpm)) BPM", tint: .roonGold) }
                    if !f.camelot.isEmpty { Badge(f.camelot, tint: .roonGold) }
                }
            }
            .lineLimit(1)
        }
    }

    // MARK: Visualizer — beat-driven equalizer fed by the analyzer's BPM/energy/
    // valence; runs while a track with a known tempo plays (opt-out in Settings).

    @ViewBuilder
    private func visualizer(_ lp: LocalPlaybackController) -> some View {
        if showVisualizer, let f = feat, f.bpm > 0 {
            BeatVisualizer(
                bpm: f.bpm,
                intensity: Double(attrs["danceability"] ?? attrs["energy"] ?? 0.55),
                warmth: Double(attrs["valence"] ?? 0.5),
                isPlaying: lp.isPlaying,
                reduceMotion: reduceMotion
            )
            .padding(.horizontal, Spacing.sm)
            .transition(.opacity)
        }
    }

    // MARK: Shuffle / repeat — bound to the local engine's own queue state.

    // MARK: Volume — the device's playback level, stacked on the loudness gain.

    private func volumeRow(_ lp: LocalPlaybackController) -> some View {
        HStack(spacing: Spacing.sm) {
            Button {
                Haptics.tap(); lp.toggleMute()
            } label: {
                Image(systemName: lp.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .foregroundStyle(.secondary)
                    .tappable44()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(lp.isMuted ? LS("localNowPlaying.unmute") : LS("localNowPlaying.mute"))

            Slider(value: $volumeValue, in: 0...100, step: 1) { editing in
                if !editing { lp.setVolume(volumeValue / 100) }
            }
            .tint(.white.opacity(0.55))
            .controlSize(.small)
            .accessibilityLabel("Volume")

            Text("\(lp.isMuted ? 0 : Int(volumeValue))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .trailing)
        }
    }

    // MARK: Feedback (like/dislike/lyrics) + up-next — same as the zone hero.

    @ViewBuilder
    private func feedbackRow(_ lp: LocalPlaybackController) -> some View {
        if let track = lp.current {
            let current = client.feedbackFor(title: track.title, artist: track.artist, album: track.album)
            HStack(spacing: Spacing.lg) {
                Button {
                    Haptics.tap()
                    Task { await client.setFeedback(.like, title: track.title, artist: track.artist, album: track.album) }
                } label: {
                    Image(systemName: current == .like ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .font(.title3)
                        .foregroundStyle(current == .like ? Color.roonGold : .primary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LS("localNowPlaying.like"))
                .accessibilityAddTraits(current == .like ? .isSelected : [])

                Button {
                    Haptics.tap()
                    Task { await client.setFeedback(.dislike, title: track.title, artist: track.artist, album: track.album) }
                } label: {
                    Image(systemName: current == .dislike ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .font(.title3)
                        .foregroundStyle(current == .dislike ? Color.roonDanger : .primary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LS("localNowPlaying.dislike"))
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
                .accessibilityLabel(LS("localNowPlaying.lyrics"))

                // Everything you might want but rarely mid-song, behind one
                // glyph. Four icons on the screen became one; nothing was lost.
                Menu {
                    Button {
                        startingAdventure = true
                        Task {
                            if let t = lp.current {
                                await client.playSonicAdventure(title: t.title, artist: t.artist, album: t.album)
                            }
                            startingAdventure = false
                        }
                    } label: { Label(LS("nowPlaying.journey"), systemImage: "map") }
                        .disabled(startingAdventure || lp.current == nil)

                    Button {
                        if let t = lp.current {
                            similarSeed = SonicSeed(title: t.title, artist: t.artist,
                                                    album: t.album, imageKey: t.imageKey)
                        }
                    } label: { Label(LS("localNowPlaying.sonicallySimilar"), systemImage: "waveform.path.ecg") }
                        .disabled(lp.current == nil)

                    Button {
                        showWall = true
                    } label: { Label(LS("nowPlaying.wallDisplay"), systemImage: "play.tv") }
                        .disabled(lp.current == nil)

                    if let t = lp.current {
                        ShareCardButton(title: t.title.displayTitle,
                                        artist: t.artist.isEmpty ? nil : t.artist,
                                        imageKey: t.imageKey, inMenu: true)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.title3)
                        .foregroundStyle(.primary)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel(LS("localNowPlaying.more"))

                if let next = nextLocalItem(lp) {
                    Spacer(minLength: Spacing.sm)
                    nextUpPill(next, lp).layoutPriority(-1)
                } else {
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func nextUpPill(_ next: LocalPlaybackController.Track, _ lp: LocalPlaybackController) -> some View {
        HStack(spacing: Spacing.sm) {
            VStack(alignment: .trailing, spacing: 1) {
                LT("localNowPlaying.upNext").font(.caption2).foregroundStyle(.secondary)
                Text(next.title).font(.caption.weight(.medium)).lineLimit(1)
                if !next.artist.isEmpty {
                    Text(next.artist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            AlbumArtView(imageKey: next.imageKey, size: 36)
            Image(systemName: "forward.end.fill")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { Haptics.tap(); lp.next() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(LS("Hierna: \(next.title)"))
        .accessibilityHint(LS("localNowPlaying.tapToContinue"))
    }

    private func nextLocalItem(_ lp: LocalPlaybackController) -> LocalPlaybackController.Track? {
        lp.queue.indices.contains(lp.index + 1) ? lp.queue[lp.index + 1] : nil
    }

    private func refreshFeatures(_ lp: LocalPlaybackController) async {
        if let track = lp.current {
            feat = await client.featuresFor(title: track.title, artist: track.artist, album: track.album)
            attrs = await client.attributesFor(title: track.title, artist: track.artist, album: track.album)
        } else {
            feat = nil
            attrs = [:]
        }
    }

    // MARK: Error + status footer

    private func errorLine(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.footnote)
            .foregroundStyle(Color.roonDanger)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .frame(maxWidth: .infinity)
    }

    /// Just the "what got skipped" note. There is deliberately no stop button
    /// here: a music player's marquee screen offers play/pause, not a destructive
    /// stop-and-wipe. It was a leftover from when listening on this device was
    /// the exception you switched out of. Stopping is still reachable from the
    /// mini-player, and the queue screen can clear what's upcoming.
    @ViewBuilder
    private func statusFooter(_ lp: LocalPlaybackController) -> some View {
        if let summary = client.lastLocalPlaybackSummary, summary.blocked > 0 {
            Text("\(summary.playable) van \(summary.requested) speelbaar hier · \(summary.blocked) Qobuz/stream overgeslagen")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    // MARK: Helpers

    private func formatTime(_ seconds: Double) -> String {
        let s = Int(max(0, seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
