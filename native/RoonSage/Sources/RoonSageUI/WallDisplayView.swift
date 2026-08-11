import RoonSageCore
import SwiftUI

/// A dedicated "listening room" display for a TV or tablet, on top of the
/// immersive Now Playing: large artwork on a dominant-colour wash, with an
/// info panel that auto-rotates between the track, the artist bio, and the album
/// review (reusing the editorial cache from feature #3). Chrome — a close button
/// and the rotation-interval stepper — is hidden until you tap.
///
/// (Related-artists and an optional YouTube panel are future additions; this
/// ships the rotating art + editorial core.)
@MainActor
struct WallDisplayView: View {
    @Environment(RoonClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    // Reads the ACTIVE output rather than taking a zone: the wall display used
    // to be constructed with `WallDisplayView(zone:)` from the zone hero only, so
    // it was unreachable on this device — the one output most likely to be
    // propped up on a shelf as a display.

    @AppStorage("wallDisplayInterval") private var interval: Double = 12   // seconds per panel
    @State private var panelIndex = 0
    @State private var tint: Color = .black
    @State private var bio: Editorial?
    @State private var review: Editorial?
    @State private var showChrome = false

    private enum Panel: Equatable { case track, bio(Editorial), review(Editorial) }

    /// Panels grow as editorial loads; `panelIndex` is always taken modulo count.
    private var panels: [Panel] {
        var p: [Panel] = [.track]
        if let bio, !bio.body.isEmpty { p.append(.bio(bio)) }
        if let review, !review.body.isEmpty { p.append(.review(review)) }
        return p
    }

    private var artURL: URL? {
        client.activeNowPlaying?.imageKey.flatMap { client.imageURL(forKey: $0, size: 1200) }
    }

    var body: some View {
        ZStack {
            LinearGradient(colors: [tint.opacity(0.85), .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            content
            if showChrome { chrome.transition(.opacity) }
        }
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .onTapGesture { withAnimation(Motion.quick) { showChrome.toggle() } }
        .task(id: artURL) { await loadArtTint() }
        .task(id: client.activeNowPlaying?.title) { await loadEditorial() }
        .task(id: interval) { await rotate() }
        #if os(macOS)
        .frame(minWidth: 800, minHeight: 600)
        #endif
    }

    // MARK: - Layout

    private var content: some View {
        // Landscape (TV/iPad/Mac) reads best side-by-side; a narrow phone stacks.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 48) {
                artwork.frame(maxWidth: 520)
                panel.frame(maxWidth: 520)
            }
            .padding(56)
            VStack(spacing: 32) {
                artwork.frame(maxHeight: 360)
                panel
            }
            .padding(32)
        }
    }

    private var artwork: some View {
        Group {
            if let artURL {
                CachedArtImage(url: artURL) { ProgressView().controlSize(.large) }
                    .aspectRatio(1, contentMode: .fit)
            } else {
                RoundedRectangle(cornerRadius: 24).fill(.white.opacity(0.1))
                    .overlay(Image(systemName: "music.note").font(.system(size: 90)).foregroundStyle(.white.opacity(0.5)))
                    .aspectRatio(1, contentMode: .fit)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 24))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 16)
    }

    @ViewBuilder
    private var panel: some View {
        let np = client.activeNowPlaying
        VStack(alignment: .leading, spacing: 16) {
            switch panels[panelIndex % max(1, panels.count)] {
            case .track:
                Text(np?.title.displayTitle ?? "Er speelt niets")
                    .font(.system(size: 40, weight: .bold))
                    .lineLimit(3)
                if let artist = np?.artist {
                    Text(artist).font(.system(size: 28, weight: .medium)).foregroundStyle(.white.opacity(0.8))
                }
                if let album = np?.album {
                    Text(album).font(.system(size: 20)).foregroundStyle(.white.opacity(0.6))
                }
            case .bio(let editorial):
                panelHeader("Over de artiest", source: editorial.source)
                Text(editorial.body).font(.system(size: 22)).lineLimit(12)
            case .review(let editorial):
                panelHeader("Over dit album", source: editorial.source)
                Text(editorial.body).font(.system(size: 22)).lineLimit(12)
            }
            Spacer(minLength: 0)
            if panels.count > 1 { panelDots }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, alignment: .leading)
        .id(panelIndex)
        .transition(.opacity)
    }

    private func panelHeader(_ title: String, source: String) -> some View {
        HStack {
            Text(title.uppercased()).font(.caption.bold()).foregroundStyle(Color.roonGold)
            Spacer()
            Text("bron: \(source)").font(.caption2).foregroundStyle(.white.opacity(0.5))
        }
    }

    private var panelDots: some View {
        HStack(spacing: 8) {
            ForEach(0..<panels.count, id: \.self) { i in
                Circle()
                    .fill(i == panelIndex % panels.count ? Color.roonGold : Color.white.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
    }

    private var chrome: some View {
        VStack {
            HStack {
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white.opacity(0.85))
                }
                .buttonStyle(.plain).padding().accessibilityLabel("Sluit wanddisplay")
            }
            Spacer()
            HStack(spacing: 12) {
                Image(systemName: "timer").foregroundStyle(.white.opacity(0.7))
                Stepper("Wissel elke \(Int(interval)) s", value: $interval, in: 4...60, step: 2)
                    .frame(maxWidth: 320)
                    .foregroundStyle(.white)
            }
            .padding()
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.bottom, 24)
        }
    }

    // MARK: - Data

    @MainActor
    private func loadArtTint() async {
        guard let artURL, let colour = await ImageCache.shared.dominantColor(for: artURL) else { return }
        withAnimation(.easeInOut(duration: 0.6)) { tint = colour }
    }

    @MainActor
    private func loadEditorial() async {
        panelIndex = 0
        bio = nil; review = nil
        guard let np = client.activeNowPlaying else { return }
        if let artist = np.artist { bio = await client.artistEditorial(name: artist) }
        if let album = np.album { review = await client.albumReview(album: album, artist: np.artist) }
    }

    private func rotate() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(max(4, interval) * 1_000_000_000))
            if Task.isCancelled { break }
            let count = panels.count
            guard count > 1 else { continue }
            withAnimation(.easeInOut(duration: 0.5)) { panelIndex = (panelIndex + 1) % count }
        }
    }
}
