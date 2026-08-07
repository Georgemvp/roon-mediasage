import RoonSageCore
import SwiftUI

/// A square, shareable "now playing" card: large artwork, title + artist, on a
/// background tinted by the artwork's dominant colour. Rendered off-screen to a
/// PNG via `ImageRenderer` (see `ShareCardButton`), so the layout uses fixed point
/// sizes rather than dynamic type — it must look identical regardless of device.
struct NowPlayingShareCard: View {
    let title: String
    let artist: String?
    let artwork: Image?
    let tint: Color

    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)
            Group {
                if let artwork {
                    artwork.resizable().aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 28).fill(.white.opacity(0.12))
                        .overlay(Image(systemName: "music.note")
                            .font(.system(size: 120)).foregroundStyle(.white.opacity(0.5)))
                }
            }
            .frame(width: 520, height: 520)
            .clipShape(RoundedRectangle(cornerRadius: 28))
            .shadow(color: .black.opacity(0.35), radius: 24, y: 12)

            VStack(spacing: 10) {
                Text(title)
                    .font(.system(size: 44, weight: .bold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                if let artist, !artist.isEmpty {
                    Text(artist)
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(.white.opacity(0.82))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 40)

            Spacer(minLength: 0)
            HStack(spacing: 10) {
                Image(systemName: "music.note.house.fill")
                Text("RoonSage")
            }
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.white.opacity(0.6))
        }
        .foregroundStyle(.white)
        .padding(60)
        .frame(width: 900, height: 900)
        .background(
            LinearGradient(colors: [tint.opacity(0.9), tint.opacity(0.35), .black],
                           startPoint: .top, endPoint: .bottom))
        .environment(\.colorScheme, .dark)
    }
}

/// Share-sheet button for the now-playing hero. Pre-renders a `NowPlayingShareCard`
/// to an image (artwork + dominant-colour tint must be resolved *before* the
/// `ImageRenderer` snapshot — the renderer can't await async art), then offers it
/// through a `ShareLink`. Falls back to a dimmed, inert icon while rendering.
struct ShareCardButton: View {
    @Environment(RoonClient.self) private var client
    let title: String
    let artist: String?
    let imageKey: String?

    @State private var shareImage: Image?

    var body: some View {
        Group {
            if let shareImage {
                ShareLink(item: shareImage, preview: SharePreview(title, image: shareImage)) {
                    icon
                }
                .buttonStyle(.plain)
                .accessibilityLabel(LS("shareCard.shareAsImage"))
            } else {
                icon.opacity(0.4).accessibilityHidden(true)
            }
        }
        .task(id: renderKey) { await render() }
    }

    private var icon: some View {
        Image(systemName: "square.and.arrow.up")
            .font(.callout.weight(.semibold))
            .foregroundStyle(.secondary)
            .tappable44()
    }

    /// Re-render whenever the track (or its art) changes.
    private var renderKey: String { "\(title)|\(artist ?? "")|\(imageKey ?? "")" }

    @MainActor
    private func render() async {
        shareImage = nil
        var artwork: Image?
        var tint = Color.roonGold
        if let key = imageKey, let url = client.imageURL(forKey: key, size: 600) {
            if let img = await ImageCache.shared.image(for: url) { artwork = Image(platformImage: img) }
            if let colour = await ImageCache.shared.dominantColor(for: url) { tint = colour }
        }
        let card = NowPlayingShareCard(title: title, artist: artist, artwork: artwork, tint: tint)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2   // 900pt × 2 = 1800px square — crisp on social, reasonable file size
        if let cg = renderer.cgImage { shareImage = Image(decorative: cg, scale: 2) }
    }
}
