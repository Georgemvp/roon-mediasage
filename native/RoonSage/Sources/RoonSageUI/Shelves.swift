import RoonSageCore
import SwiftUI

/// Shared "Listen Now"-style shelf vocabulary: a cover model, a horizontal cover
/// shelf, a section header, a cover tile, and a stat card. Extracted verbatim from
/// `DiscoveryView` so the Ontdek dashboard and the Bibliotheek overview render from
/// one canonical set instead of drifting copies.
///
/// These are stateless on purpose — output availability is passed in as `zoneAvailable`
/// (any output: a Roon zone or this device — `play` routes itself)
/// rather than read from `@Environment`, so a tile can be previewed and reused from
/// any view without inheriting that view's playback plumbing.

/// A playable cover: the caller supplies both play actions (remote zone / on-device),
/// keeping playback semantics out of this shared layer.
public struct Cover: Identifiable {
    public let id: String
    public let title: String
    public let subtitle: String?
    public let imageKey: String?
    public let play: () -> Void

    public init(id: String, title: String, subtitle: String?, imageKey: String?,
                play: @escaping () -> Void) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.imageKey = imageKey
        self.play = play
    }
}

/// Edge length of one cover on a horizontal shelf, in points.
///
/// One constant instead of the literal `130` that used to appear in both the
/// artwork and the tile's `frame` — a shelf whose art and whose text column
/// disagree by a few points is what makes a row of covers look ragged.
public let coverTileSize: CGFloat = 140

/// Columns for a cover grid: three per row at compact width (an iPhone in
/// portrait), larger tiles wherever there is more room.
///
/// At a 150 pt minimum a 402 pt phone fitted exactly two columns, so a 13.000
/// album grid showed four tiles per screen. iPad and Mac keep the bigger tile —
/// they were never the cramped case, and this session could only measure the
/// phone. One definition, shared by the library grids, the artist page and the
/// full-discography screen, so the three stay one grid instead of drifting.
public func coverGridColumns(compact: Bool) -> [GridItem] {
    [GridItem(.adaptive(minimum: compact ? 112 : 150), spacing: Spacing.md)]
}

/// A section header: the title in small caps over a hairline rule, with a
/// caller-supplied trailing control (a chevron into the full list, a shuffle
/// button, or `EmptyView()`).
///
/// The gold icon that used to sit in front of every title is gone. With eight
/// sections stacked in one feed it read as eight competing marks rather than
/// eight labels, and half the vocabulary had to be learned (a house, a clock, a
/// grid) before it said anything. Small caps on a rule is the quieter form: it
/// separates the sections without decorating them.
@MainActor @ViewBuilder
public func sectionHeader<Trailing: View>(
    _ title: String, @ViewBuilder trailing: () -> Trailing
) -> some View {
    VStack(alignment: .leading, spacing: 6) {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Text(title.uppercased())
                .font(.subheadline.weight(.semibold))
                .kerning(0.6)
                .lineLimit(1)
            Spacer(minLength: Spacing.sm)
            trailing()
        }
        Divider().opacity(0.35)
    }
}

/// The chevron that opens a section's full list — the trailing control most
/// feed sections want.
///
/// A Button, never a `NavigationLink`: these headers sit inside `List` rows, and
/// a `NavigationLink` anywhere in a row makes the List draw its OWN disclosure
/// indicator at the far edge — so the section header rendered two chevrons, one
/// after the title and one against the screen edge. The caller pushes.
@MainActor
public func sectionChevron(_ action: @escaping () -> Void) -> some View {
    Button(action: action) {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.leading, Spacing.sm)
            .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
}

/// A horizontal shelf: a `sectionHeader` above a horizontally scrolling row of
/// `coverTile`s. `zoneAvailable` gates the tiles' remote-play affordance.
@MainActor @ViewBuilder
public func shelf<Trailing: View>(
    _ title: String, covers: [Cover], zoneAvailable: Bool,
    @ViewBuilder trailing: () -> Trailing
) -> some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
        sectionHeader(title, trailing: trailing)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: Spacing.md) {
                ForEach(covers) { coverTile($0, zoneAvailable: zoneAvailable) }
            }
            .padding(.horizontal, 2)
        }
    }
}

/// The feed's other row type: four compact rows under one header, each a small
/// square thumb with title, subtitle and an overflow menu.
///
/// A feed of nothing but cover shelves reads as one texture repeated — you
/// cannot tell "recently added" from "most played" without reading every
/// heading. Alternating a shelf with a list gives the page a rhythm, and a list
/// row can carry a long album title that a 130 pt tile has to truncate.
@MainActor @ViewBuilder
public func compactRows<Trailing: View, Menu: View>(
    _ title: String, covers: [Cover], zoneAvailable: Bool,
    @ViewBuilder trailing: () -> Trailing,
    @ViewBuilder menu: @escaping (Cover) -> Menu
) -> some View {
    VStack(alignment: .leading, spacing: Spacing.md) {
        sectionHeader(title, trailing: trailing)
        VStack(spacing: 0) {
            ForEach(covers) { cover in
                compactRow(cover, zoneAvailable: zoneAvailable, menu: menu)
            }
        }
    }
}

@MainActor
private func compactRow<Menu: View>(
    _ c: Cover, zoneAvailable: Bool, @ViewBuilder menu: @escaping (Cover) -> Menu
) -> some View {
    HStack(spacing: Spacing.md) {
        Button {
            Haptics.tap()
            c.play()
        } label: {
            HStack(spacing: Spacing.md) {
                AlbumArtView(imageKey: c.imageKey, size: 46, cornerRadius: Radius.md)
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.title).font(.body).lineLimit(1)
                    if let sub = c.subtitle {
                        Text(sub).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!zoneAvailable)
        SwiftUI.Menu {
            menu(c)
        } label: {
            // Rotated, because SF Symbols has no vertical ellipsis: the upright
            // form is what an overflow menu looks like in a list. `.tint` as well
            // as `.foregroundStyle`, or the menu label inherits the app's gold
            // accent and the control reads as an action instead of a handle.
            Image(systemName: "ellipsis")
                .font(.body)
                .rotationEffect(.degrees(90))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 36)
                .contentShape(Rectangle())
        }
        .tint(.secondary)
        .accessibilityLabel(LS("library.moreActions"))
    }
    .padding(.vertical, 6)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(c.subtitle.map {
        String(format: LS("shelf.playTitleByArtist"), c.title, $0)
    } ?? String(format: LS("shelf.playTitle"), c.title))
    .accessibilityIdentifier("compact.row")
}

/// A single cover: artwork with a play badge, title, and subtitle. Tapping plays to
/// the active zone; the context menu offers remote / on-device playback.
@MainActor
public func coverTile(_ c: Cover, zoneAvailable: Bool) -> some View {
    Button {
        Haptics.tap()
        c.play()
    } label: {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            AlbumArtView(imageKey: c.imageKey, size: coverTileSize)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md))
                .shadow(color: .roonShadow, radius: 4, y: 2)
                // Smaller and white-on-scrim rather than a gold disc. At `.title2`
                // in gold it was the loudest thing in a feed of eight shelves —
                // the badge competed with the artwork it sat on. It still has to
                // be there: tapping a cover plays, and an invisible affordance is
                // worse than a loud one.
                .overlay(alignment: .bottomTrailing) {
                    Image(systemName: "play.circle.fill")
                        .font(.body)
                        .foregroundStyle(.white, .black.opacity(0.35))
                        .shadow(color: .black.opacity(0.4), radius: 2, y: 1)
                        .padding(6)
                }
            Text(c.title).font(.caption.weight(.medium)).lineLimit(1)
            if let sub = c.subtitle {
                Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .frame(width: coverTileSize)
    }
    .buttonStyle(.plain)
    .disabled(!zoneAvailable)
    .accessibilityLabel(c.subtitle.map {
        String(format: LS("shelf.playTitleByArtist"), c.title, $0)
    } ?? String(format: LS("shelf.playTitle"), c.title))
    // Language-independent handle for the UI walk: every visible label here is
    // localised, so matching on Dutch would make the test pass or fail on the
    // simulator's language instead of on the UI.
    .accessibilityIdentifier("cover.tile")
    .contextMenu {
        Button(LS("bm.playNow"), systemImage: "play.fill") { Haptics.tap(); c.play() }
            .disabled(!zoneAvailable)
    }
}

/// A compact metric tile: a big monospaced value over a caption label.
public struct StatCard: View {
    let label: String
    let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }

    public var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.bold().monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.lg))
    }
}
