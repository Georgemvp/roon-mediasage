import SwiftUI
import RoonSageCore

/// Loads album art from the Roon HTTP image API.
/// Falls back to a music-note placeholder on missing key or network error.
public struct AlbumArtView: View {
    @Environment(RoonClient.self) private var client
    let imageKey: String?
    var size: CGFloat = 56
    var cornerRadius: CGFloat? = nil
    /// Grid-cell mode: stay square but take the column's width instead of a
    /// fixed one. `size` then only sizes the requested image, not the layout.
    var fillsWidth = false

    public init(imageKey: String?, size: CGFloat = 56, cornerRadius: CGFloat? = nil) {
        self.imageKey = imageKey
        self.size = size
        self.cornerRadius = cornerRadius
    }

    /// Square art that fills the width it is offered — for `LazyVGrid` cells,
    /// where the column width is only known at layout time.
    ///
    /// A fixed `size:` inside an `.adaptive` column left the art narrower than
    /// its cell, so the covers sat left of centre with a ragged gutter between
    /// them and the grid never read as a grid. `sizeHint` is the pixel size we
    /// ask the server for, not a frame.
    public init(imageKey: String?, fillingWidth sizeHint: CGFloat, cornerRadius: CGFloat) {
        self.imageKey = imageKey
        self.size = sizeHint
        self.cornerRadius = cornerRadius
        self.fillsWidth = true
    }

    public var body: some View {
        let r = cornerRadius ?? size * 0.12
        let url = imageKey.flatMap { client.imageURL(forKey: $0, size: Int(size * 2)) }
        if fillsWidth {
            Color.clear
                .aspectRatio(1, contentMode: .fit)
                .overlay { CachedArtImage(url: url) { placeholder } }
                .clipShape(RoundedRectangle(cornerRadius: r))
        } else {
            CachedArtImage(url: url) { placeholder }
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: r))
        }
    }

    private var placeholder: some View {
        ZStack {
            // A soft gold-tinted gradient reads as "artwork missing" far more
            // gracefully than a flat grey tile sitting next to real covers.
            RoundedRectangle(cornerRadius: cornerRadius ?? size * 0.12)
                .fill(LinearGradient(
                    colors: [Color.roonGold.opacity(0.22), Color.roonGold.opacity(0.06)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: "music.note")
                .font(.system(size: size * 0.34, weight: .semibold))
                .foregroundStyle(Color.roonGold.opacity(0.7))
        }
    }
}
