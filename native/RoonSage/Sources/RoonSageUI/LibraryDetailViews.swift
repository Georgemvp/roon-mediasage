import AudioAnalysis
import RoonSageCore
import SwiftUI

// MARK: - Album detail (drill-down from the album grid)

@MainActor
struct AlbumDetailView: View {
    @Environment(RoonClient.self) private var client
    let album: DatabaseManager.AlbumResult
    @State private var tracks: [DatabaseManager.LibraryTrackRow] = []
    @State private var isLoading = true
    @State private var infoTrack: DatabaseManager.LibraryTrackRow?
    @State private var similarSeed: SonicSeed?
    /// Other editions of this release in the library (remasters, deluxe,
    /// box-set copies) — grouped by the LMS-style version key.
    @State private var otherVersions: [DatabaseManager.AlbumResult] = []
    @State private var review: Editorial?
    @State private var reviewExpanded = false

    var body: some View {
        List {
            Section {
                header
                    .listRowSeparator(.hidden)
                    .listRowInsets(EdgeInsets(top: Spacing.md, leading: Spacing.lg,
                                              bottom: Spacing.md, trailing: Spacing.lg))
            }
            if let review {
                Section(LS("libraryDetail.aboutAlbum")) { reviewSection(review) }
            }
            if isLoading {
                ProgressView().frame(maxWidth: .infinity).listRowSeparator(.hidden)
            } else {
                ForEach(tracks) { track in
                    LibraryTrackRow(track: track, canPlay: client.hasActiveOutput) {
                        play([track])
                    }
                    .contextMenu {
                        PlayActionsMenu(fetch: { [track.asTrackRecord] }, trackRadioSeed: track.asTrackRecord)
                        Divider()
                        Button(LS("libraryDetail.sonicallySimilar"), systemImage: "waveform.path.ecg") {
                            similarSeed = SonicSeed(title: track.title, artist: track.artist,
                                                    album: track.album, imageKey: track.imageKey)
                        }
                        Button(LS("libraryDetail.info"), systemImage: "info.circle") { infoTrack = track }
                    }
                }
            }
            if !otherVersions.isEmpty {
                Section(LS("libraryDetail.otherVersions")) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: Spacing.lg) {
                            ForEach(otherVersions) { version in
                                NavigationLink(value: version) {
                                    VStack(alignment: .leading, spacing: 4) {
                                        AlbumArtView(imageKey: version.imageKey, size: 110, cornerRadius: Radius.md)
                                        Text(version.album).font(.caption).lineLimit(2)
                                            .frame(width: 110, alignment: .leading)
                                        if let y = version.year {
                                            Text(String(y)).font(.caption2).foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, Spacing.xs)
                    }
                    .listRowSeparator(.hidden)
                }
            }
        }
        .sheet(item: $infoTrack) { TrackInfoSheet(track: $0) }
        .similarTracksSheet(item: $similarSeed)
        .navigationTitle(album.album)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: album.albumKey) {
            isLoading = true
            await client.ensureFavoritesLoaded()
            await client.ensureBookmarksLoaded()
            tracks = await client.tracksForAlbum(album.albumKey)
            isLoading = false
            // Sibling editions: search on the *normalized* title (edition
            // suffixes stripped), keep exact version-key matches, drop self.
            let key = AlbumGrouping.versionKey(album: album.album, artist: album.artist)
            let query = TrackIdentity.cleanTitle(album.album)
            otherVersions = await client.searchAlbums(query: query).filter {
                $0.albumKey != album.albumKey
                    && AlbumGrouping.versionKey(album: $0.album, artist: $0.artist) == key
            }
            // Editorial loads after the fold — never blocks the tracklist.
            review = await client.albumReview(album: album.album, artist: album.artist)
        }
    }

    /// Expandable album review ("2 regels, tik om uit te klappen"), with source
    /// attribution — mirrors the artist bioSection pattern.
    private func reviewSection(_ editorial: Editorial) -> some View {
        Button {
            withAnimation(Motion.quick) { reviewExpanded.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(editorial.body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(reviewExpanded ? nil : 3)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack {
                    (reviewExpanded ? LT("libraryDetail.showLess") : LT("libraryDetail.readMore"))
                        .font(.caption.bold())
                        .foregroundStyle(Color.roonGold)
                    Spacer()
                    Text(String(format: LS("libraryDetail.sourceLine"), editorial.source))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .buttonStyle(.plain)
    }

    /// Cover and titles on one row, the five verbs on the next.
    ///
    /// They all used to share the column beside a 120 pt cover: on an iPhone
    /// that leaves about 250 pt for five controls, and the one with a word in it
    /// lost. "Speel" rendered as a gold capsule with no label at all. Same shape
    /// of fix as the artist header — the row of verbs gets the full width.
    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .top, spacing: Spacing.lg) {
                AlbumArtView(imageKey: album.imageKey, size: 110, cornerRadius: Radius.lg)
                VStack(alignment: .leading, spacing: 4) {
                    Text(album.album).font(.title3.bold()).lineLimit(3)
                    if let a = album.artist {
                        Text(a).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(subtitle).font(.caption).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: Spacing.sm) {
                // Play + queue both follow the active output, so they work on
                // this device as well as on a zone — hence no separate
                // on-device button, and no zone in the disabled condition.
                Button { play(tracks) } label: {
                    Label(LS("libraryDetail.play"), systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Color.roonGold)
                .disabled(!client.hasActiveOutput || tracks.isEmpty)
                // Queue kept icon-only so the row fits on iPhone.
                Button { queue(tracks) } label: { Image(systemName: "text.append") }
                    .buttonStyle(.bordered)
                    .disabled(!client.hasActiveOutput || tracks.isEmpty)
                    .accessibilityLabel(LS("libraryDetail.addToQueue"))
                    .help(LS("libraryDetail.addToQueue"))
                Button {
                    Haptics.tap()
                    Task {
                        await client.startAlbumRadio(albumKey: album.albumKey, title: album.album,
                                                     artist: album.artist, imageKey: album.imageKey)
                    }
                } label: { Image(systemName: "dot.radiowaves.left.and.right") }
                    .buttonStyle(.bordered)
                    .disabled(!client.hasActiveOutput)
                    .accessibilityLabel(LS("libraryDetail.albumRadio"))
                    .help(LS("libraryDetail.albumRadioHelp"))
                FavoriteStarButton(isOn: client.isFavoriteAlbum(album: album.album, artist: album.artist)) {
                    Task { await client.toggleFavoriteAlbum(album: album.album, artist: album.artist) }
                }
                BookmarkButton(isOn: client.isBookmarkedAlbum(album: album.album, artist: album.artist)) {
                    Task { await client.toggleBookmarkAlbum(album: album.album, artist: album.artist) }
                }
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let y = album.year { parts.append(String(y)) }
        parts.append(album.trackCount == 1
            ? String(format: LS("library.trackCountOne"), album.trackCount)
            : String(format: LS("library.trackCountMany"), album.trackCount))
        return parts.joined(separator: " · ")
    }

    private func record(_ t: DatabaseManager.LibraryTrackRow) -> TrackRecord {
        TrackRecord(id: t.id, title: t.title, artist: t.artist, album: t.album,
                    year: t.year, isLive: t.isLive, imageKey: t.imageKey)
    }

    /// Play now on the active output — a Roon zone, or this device.
    private func play(_ rows: [DatabaseManager.LibraryTrackRow]) {
        guard !rows.isEmpty else { return }
        Haptics.tap()
        Task { await client.playToActiveOutput(rows.map(record)) }
    }

    /// Append to the active output's queue — Roon's, or this device's.
    private func queue(_ rows: [DatabaseManager.LibraryTrackRow]) {
        guard !rows.isEmpty else { return }
        Haptics.tap()
        Task { await client.queueToActiveOutput(rows.map(record), next: false) }
    }
}

// MARK: - Artist detail (drill-down from the artist grid)

@MainActor
struct ArtistDetailView: View {
    @Environment(RoonClient.self) private var client
    let artist: DatabaseManager.ArtistResult
    @State private var albums: [DatabaseManager.AlbumResult] = []
    @State private var isLoading = true
    // Artiestpagina 2.0 (LMS-audit): bio + meest gespeeld + vergelijkbaar.
    // Each loads independently and simply stays absent when its source is
    // unavailable (no Last.fm key, no play history, no embeddings).
    @State private var bio: String?
    @State private var bioExpanded = false
    @State private var topPlayed: [DatabaseManager.LibraryTrackRow] = []
    @State private var similar: [ArtistSimilarity.Result] = []
    @State private var similarArtists: [DatabaseManager.ArtistResult] = []

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var compactWidth: Bool { hSizeClass == .compact }
    #else
    private var compactWidth: Bool { false }
    #endif
    private var columns: [GridItem] { coverGridColumns(compact: compactWidth) }

    /// How many releases a discography section shows before it hands the rest
    /// over to its own screen. Two rows of three on a phone.
    private let discographyPreview = 6

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.lg) {
                header

                if let bio, !bio.isEmpty { bioSection(bio) }

                if !topPlayed.isEmpty { topPlayedSection }

                if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding()
                } else {
                    // LMS-style discography sections (Albums / EP's & singles /
                    // Live / Compilaties); headers only when there's actually
                    // more than one type to separate.
                    let grouped = groupedAlbums
                    let showHeaders = grouped.count > 1
                    ForEach(grouped, id: \.type) { group in
                        discographySection(group.type, group.albums, showHeader: showHeaders)
                    }
                }

                if !similarArtists.isEmpty { similarSection }
            }
            .padding(Spacing.lg)
        }
        .navigationTitle(artist.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task(id: artist.name) {
            isLoading = true
            await client.ensureFavoritesLoaded()
            await client.ensureBookmarksLoaded()
            albums = await client.albumsByArtist(artist.name)
            isLoading = false
            // Secondary sections load after the fold, never blocking the albums.
            bio = await client.artistEditorial(name: artist.name)?.body
            topPlayed = await client.topPlayedTracks(artist: artist.name, limit: 5)
            similar = await client.similarLibraryArtists(to: artist.name, limit: 10)
            similarArtists = await resolveSimilar(similar)
        }
    }

    // MARK: - Header

    /// Portrait, name, counts — then the verbs on a row of their own.
    ///
    /// All five used to share one `HStack`, so "Speel alles" competed with the
    /// artist's name for the same width: on a phone the name wrapped to two
    /// lines and the button lost its label. The artist also had no picture at
    /// all, which is why the page opened flatter than the album page next to it.
    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.lg) {
                AlbumArtView(imageKey: artist.imageKey, size: 84, cornerRadius: 42)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(artist.name).font(.title2.bold()).lineLimit(2)
                    Text(LibraryView.artistSummary(albums: artist.albumCount, tracks: artist.trackCount))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: Spacing.sm) {
                Button { playArtist() } label: {
                    Label(LS("libraryDetail.playAll"), systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(Color.roonGold)
                .disabled(!client.hasActiveOutput)
                FavoriteStarButton(isOn: client.isFavoriteArtist(artist.name)) {
                    Task { await client.toggleFavoriteArtist(artist.name) }
                }
                BookmarkButton(isOn: client.isBookmarkedArtist(artist.name)) {
                    Task { await client.toggleBookmarkArtist(artist.name) }
                }
            }
        }
    }

    // MARK: - Discografie

    /// One discography group, capped at `discographyPreview`.
    ///
    /// The grid used to hold every release an artist had: 92 for Queen, 217 for
    /// the London Philharmonic Orchestra — 46 and 109 rows of covers, and the
    /// sections underneath (Live, Compilaties, "Vergelijkbaar in je bibliotheek")
    /// sat behind all of them. Six covers say what the group holds, the count
    /// says how much more there is, and the rest is one tap away — so the page
    /// is the same height whether the artist has four releases or 217.
    @ViewBuilder
    private func discographySection(_ type: AlbumGrouping.AlbumType,
                                    _ albums: [DatabaseManager.AlbumResult],
                                    showHeader: Bool) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                if showHeader {
                    Text(type.label).font(.headline)
                    Text(albums.count.formatted())
                        .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
                if albums.count > discographyPreview {
                    NavigationLink {
                        ArtistAlbumsGridView(title: artist.name, subtitle: type.label, albums: albums)
                    } label: {
                        Text(String(format: LS("libraryDetail.showAllReleases"), albums.count))
                            .font(.caption.bold())
                            .foregroundStyle(Color.roonGold)
                    }
                    .buttonStyle(.plain)
                }
            }
            LazyVGrid(columns: columns, spacing: Spacing.lg) {
                ForEach(albums.prefix(discographyPreview)) { album in
                    NavigationLink(value: album) { AlbumGridCell(album: album, showsArtist: false) }
                        .buttonStyle(.plain)
                        .contextMenu {
                            PlayActionsMenu(fetch: { [client] in
                                await client.tracksForAlbum(album.albumKey).map(\.asTrackRecord)
                            })
                        }
                }
            }
        }
    }

    // MARK: - Bio ("2 regels, tik om uit te klappen" — LMS-patroon)

    private func bioSection(_ text: String) -> some View {
        Button {
            withAnimation(Motion.quick) { bioExpanded.toggle() }
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(bioExpanded ? nil : 2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                (bioExpanded ? LT("libraryDetail.showLess") : LT("libraryDetail.readMore"))
                    .font(.caption.bold())
                    .foregroundStyle(Color.roonGold)
            }
        }
        .buttonStyle(.plain)
        .accessibilityHint("Tik om de biografie \(bioExpanded ? "in" : "uit") te klappen")
    }

    // MARK: - Meest gespeeld

    private var topPlayedSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            LT("libraryDetail.mostPlayed").font(.headline)
            ForEach(topPlayed) { track in
                // No artist on these rows: it is the name at the top of the
                // page, repeated five times, and it was the thing crowding the
                // album out of the subtitle.
                LibraryTrackRow(track: track, canPlay: client.hasActiveOutput, showsArtist: false) {
                    playRows([track])
                }
                .contextMenu { PlayActionsMenu(fetch: { [track.asTrackRecord] }, trackRadioSeed: track.asTrackRecord) }
            }
        }
    }

    // MARK: - Vergelijkbaar in je bibliotheek

    private var similarSection: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            LT("libraryDetail.similarInLibrary").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Spacing.lg) {
                    ForEach(similarArtists) { a in
                        NavigationLink(value: a) {
                            VStack(spacing: 6) {
                                AlbumArtView(imageKey: a.imageKey, size: 96, cornerRadius: 48)
                                Text(a.name).font(.caption).lineLimit(2)
                                    .multilineTextAlignment(.center)
                                    .frame(width: 100)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, Spacing.xs)
            }
        }
    }

    /// Discography sections in display order; empty types are dropped.
    private var groupedAlbums: [(type: AlbumGrouping.AlbumType, albums: [DatabaseManager.AlbumResult])] {
        var byType: [AlbumGrouping.AlbumType: [DatabaseManager.AlbumResult]] = [:]
        for album in albums {
            byType[AlbumGrouping.classify(album: album.album, trackCount: album.trackCount), default: []]
                .append(album)
        }
        return AlbumGrouping.AlbumType.allCases.compactMap { type in
            guard let list = byType[type], !list.isEmpty else { return nil }
            return (type, list)
        }
    }

    /// Map similarity results (names) onto library artist rows for navigation;
    /// names that don't resolve are dropped.
    private func resolveSimilar(_ results: [ArtistSimilarity.Result]) async -> [DatabaseManager.ArtistResult] {
        var out: [DatabaseManager.ArtistResult] = []
        for r in results {
            let hits = await client.searchArtists(query: r.name)
            if let hit = hits.first(where: { $0.name.lowercased() == r.name.lowercased() }) ?? hits.first {
                out.append(hit)
            }
        }
        return out
    }

    private func rowRecord(_ t: DatabaseManager.LibraryTrackRow) -> TrackRecord {
        TrackRecord(id: t.id, title: t.title, artist: t.artist, album: t.album,
                    year: t.year, isLive: t.isLive, imageKey: t.imageKey)
    }

    private func playRows(_ rows: [DatabaseManager.LibraryTrackRow]) {
        guard !rows.isEmpty else { return }
        Haptics.tap()
        Task { await client.playToActiveOutput(rows.map(rowRecord)) }
    }

    /// Play this artist on the active output — a Roon zone, or this device.
    private func playArtist() {
        Haptics.tap()
        Task { await client.playArtist(name: artist.name) }
    }
}

// MARK: - One discography section, in full

/// Everything in one release group, pushed from the artist page.
///
/// The links here name their destination instead of pushing an
/// `AlbumResult` value, even though the Bibliotheek stack registers a
/// `navigationDestination` for exactly that type. This screen is itself pushed
/// by a destination-based link, and a value pushed on top of one of those is
/// dropped by the stack: the album detail appeared, ran its `.task` (the
/// Wikipedia review fetch shows up in the log) and popped straight back to this
/// grid. Same-kind links all the way down is the fix.
@MainActor
struct ArtistAlbumsGridView: View {
    let title: String
    let subtitle: String
    let albums: [DatabaseManager.AlbumResult]

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    private var compactWidth: Bool { hSizeClass == .compact }
    #else
    private var compactWidth: Bool { false }
    #endif
    private var columns: [GridItem] { coverGridColumns(compact: compactWidth) }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Spacing.lg) {
                ForEach(albums) { album in
                    NavigationLink {
                        AlbumDetailView(album: album)
                    } label: {
                        AlbumGridCell(album: album, showsArtist: false)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(Spacing.lg)
        }
        .navigationTitle(subtitle)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 0) {
                    Text(subtitle).font(.headline).lineLimit(1)
                    Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        #endif
    }
}

// MARK: - Favorite star (shared by album + artist headers)

@MainActor
struct FavoriteStarButton: View {
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Image(systemName: isOn ? "star.fill" : "star")
                .foregroundStyle(isOn ? Color.roonGold : .secondary)
        }
        .buttonStyle(.bordered)
        .accessibilityLabel(isOn ? LS("libraryDetail.removeFavorite") : LS("libraryDetail.markFavorite"))
        .help(isOn ? LS("libraryDetail.removeFavorite") : LS("libraryDetail.markFavorite"))
    }
}
