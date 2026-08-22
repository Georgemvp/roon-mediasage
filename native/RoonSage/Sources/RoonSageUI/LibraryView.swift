import RoonSageCore
import SwiftUI

@MainActor
public struct LibraryView: View {
    /// Search-first variant, used by the Zoek tab.
    ///
    /// The combined artist/album/track search already lives here (readiness P7),
    /// wired to `UnifiedSearch`, the "toon alles" drill-down and the sonic
    /// hand-off. Giving the search tab its own copy of that would have been a
    /// second implementation to keep in step — the exact mistake the two Now
    /// Playing screens were. So the tab reuses this view and only asks it to
    /// open on the search box instead of on the overview.
    private let searchOnly: Bool

    public init() { self.searchOnly = false }
    public init(searchOnly: Bool) { self.searchOnly = searchOnly }

    @Environment(RoonClient.self) private var client
    @State private var searchText = ""
    @State private var selectedTag: String?
    @State private var tracks: [DatabaseManager.LibraryTrackRow] = []
    @State private var albums: [DatabaseManager.AlbumResult] = []
    @State private var artists: [DatabaseManager.ArtistResult] = []
    @State private var tags: [(tag: String, count: Int)] = []
    @State private var isLoadingTracks = false
    @State private var isLoadingGrid = false
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    /// Combined artist/album/track results for the overview's search box (P7).
    /// nil = not searching; non-nil and empty = searched, found nothing.
    @State private var unified: RoonClient.SearchResults?
    @State private var sort: SortField = .title
    @State private var viewMode: ViewMode = .overview
    /// Grid filter: only starred albums/artists (LMS "Starred" browse mode).
    @State private var favoritesOnly = false
    @State private var selection = Set<String>()
    // Album grid multi-select (a LazyVGrid can't use List(selection:)). Ordered so
    // the bulk queue follows the order the user tapped the albums in.
    @State private var isSelectingAlbums = false
    @State private var albumSelection: [String] = []
    @State private var showSaveSheet = false
    @State private var newPlaylistName = ""
    @State private var infoTrack: DatabaseManager.LibraryTrackRow?
    @State private var similarSeed: SonicSeed?

    // Overview landing state — loaded once (guarded by `overviewLoaded`) and
    // refreshed when the library re-syncs (via `reload()` on `client.trackCount`).
    @State private var stats: DatabaseManager.LibraryStats?
    @State private var analyzedTotal = 0
    @State private var analyzedMatched = 0
    @State private var librarySeconds: Double = 0
    @State private var recentlyAdded: [DatabaseManager.LibraryTrackRow] = []
    @State private var recentPlayed: [DatabaseManager.LibraryTrackRow] = []
    @State private var forgotten: [TrackRecord] = []
    @State private var facets: RoonClient.RadioFacetOptions?
    @State private var overviewLoaded = false

    // Pagination cursors for the browse list + grids (offset = current array count).
    @State private var tracksReachedEnd = false
    @State private var albumsReachedEnd = false
    @State private var artistsReachedEnd = false
    @State private var loadingMore = false
    @State private var seenTrackKeys = Set<String>()
    private let pageSize = 200
    private let gridPageSize = 120

    /// Library modes: an overview landing, then the flat track list / album / artist grids.
    enum ViewMode: String, CaseIterable, Identifiable {
        case overview, tracks, albums, artists
        var id: String { rawValue }
        var label: String {
            switch self {
            case .overview: LS("library.modeOverview"); case .tracks: LS("library.tracks")
            case .albums: LS("bm.section.albums"); case .artists: LS("bm.section.artists")
            }
        }
        var icon: String {
            switch self {
            case .overview: "house"; case .tracks: "music.note.list"
            case .albums: "square.grid.2x2"; case .artists: "person.2"
            }
        }
    }

    private let gridColumns = [GridItem(.adaptive(minimum: 150), spacing: Spacing.lg)]

    enum SortField: String, CaseIterable, Identifiable {
        case title = "Title", artist = "Artist", album = "Album", year = "Year", bpm = "BPM", random = "Random"
        // LMS-style browse modes: these rank the *dataset* (SQL / play stats),
        // not the fetched page — see reloadTracks.
        case recentlyAdded = "RecentlyAdded", mostPlayed = "MostPlayed", recentlyPlayed = "RecentlyPlayed"
        var id: String { rawValue }
        /// Weergavenaam (NL); rawValue blijft het stabiele ID.
        var label: String {
            switch self {
            case .title: LS("library.sortTitle"); case .artist: LS("library.sortArtist"); case .album: LS("library.sortAlbum")
            case .year: LS("library.sortYear"); case .bpm: "BPM"; case .random: LS("library.sortRandom")
            case .recentlyAdded: LS("library.recentlyAdded")
            case .mostPlayed: LS("library.sortMostPlayed")
            case .recentlyPlayed: LS("library.sortRecentlyPlayed")
            }
        }
    }

    /// Cached sort+dedup result. This used to be a computed property, which
    /// re-ran a localized O(n log n) sort (and reshuffled `.random`!) on every
    /// body evaluation — selection changes, keystrokes, sync ticks. Now it's
    /// recomputed only when `tracks` or `sort` actually change.
    @State private var displayTracks: [DatabaseManager.LibraryTrackRow] = []

    private nonisolated static func sortAndDedupe(
        _ tracks: [DatabaseManager.LibraryTrackRow], by sort: SortField
    ) -> [DatabaseManager.LibraryTrackRow] {
        let sorted: [DatabaseManager.LibraryTrackRow]
        switch sort {
        case .title:  sorted = tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artist: sorted = tracks.sorted { ($0.artist ?? "").localizedCaseInsensitiveCompare($1.artist ?? "") == .orderedAscending }
        case .album:  sorted = tracks.sorted { ($0.album ?? "").localizedCaseInsensitiveCompare($1.album ?? "") == .orderedAscending }
        case .year:   sorted = tracks.sorted { ($0.year ?? 0) < ($1.year ?? 0) }
        case .bpm:    sorted = tracks.sorted { ($0.bpm ?? 0) < ($1.bpm ?? 0) }
        case .random: sorted = tracks.shuffled()
        case .recentlyAdded, .mostPlayed, .recentlyPlayed:
            sorted = tracks   // already ranked by the fetch (SQL / play stats)
        }
        // Deduplicate: keep the first occurrence of each artist+title pair so
        // remasters, deluxe editions, and box-set copies don't all show up.
        var seen = Set<String>()
        return sorted.filter { track in
            let key = "\(track.artist?.lowercased() ?? "")|\(track.title.lowercased())"
            return seen.insert(key).inserted
        }
    }

    public var body: some View {
        // The mode's scroll view is the ROOT content so it inherits the tab's bottom
        // safe-area inset (the shared NowPlayingBar) — a List nested in a VStack does
        // not, which left the mini-player floating over the last rows. The header
        // (sync banner + picker + track tag chips) and the selection bar ride in
        // safe-area insets instead, so both stay clear of the content.
        modeContent
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                if client.isSyncing { SyncProgressBanner() }
                // On the search tab the picker is chrome you didn't ask for —
                // until "toon alles" drills into a full list, when it becomes
                // the way back to the combined result.
                if !searchOnly || viewMode != .overview { modePicker }
                if viewMode == .tracks, !tags.isEmpty { tagChips }
            }
            .background(.bar)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if viewMode == .tracks, !selection.isEmpty { selectionBar }
            else if viewMode == .albums, isSelectingAlbums, !albumSelection.isEmpty { albumSelectionBar }
        }
        .animation(Motion.quick, value: selection.isEmpty)
        .animation(Motion.quick, value: albumSelection.isEmpty)
        .navigationDestination(for: DatabaseManager.AlbumResult.self) { AlbumDetailView(album: $0) }
        .navigationDestination(for: DatabaseManager.ArtistResult.self) { ArtistDetailView(artist: $0) }
        .navigationDestination(for: LibraryFilter.self) { FilteredTracksView(filter: $0) }
        .screenTitle(String(format: LS("library.titleWithCount"), client.trackCount))
        .searchable(text: $searchText, prompt: searchPrompt)
        // NOT auto-focused on the Zoek tab, though it is tempting: raising the
        // keyboard on appear takes the tab bar with it, so you land on Zoek and
        // cannot leave it again without dismissing a keyboard you never asked
        // for. Measured, not assumed — with autofocus on, the UI walk could no
        // longer select a single tab (2026-08-22). One extra tap beats a screen
        // you can't get out of.
        .toolbar {
            ToolbarItem {
                if isSearching {
                    ProgressView().controlSize(.small)
                }
            }
            if viewMode == .tracks {
                ToolbarItem {
                    Picker(LS("library.sort"), selection: $sort) {
                        ForEach(SortField.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .help(LS("library.sortTracksHelp"))
                }
            } else if viewMode == .albums || viewMode == .artists {
                ToolbarItem {
                    Button {
                        favoritesOnly.toggle()
                    } label: {
                        Image(systemName: favoritesOnly ? "star.fill" : "star")
                            .foregroundStyle(favoritesOnly ? Color.roonGold : .secondary)
                    }
                    .accessibilityLabel(LS("library.favoritesOnly"))
                    .help(favoritesOnly ? LS("library.showAll") : LS("library.favoritesOnly"))
                }
            }
            if viewMode == .albums, !visibleAlbums.isEmpty {
                ToolbarItem {
                    Button {
                        isSelectingAlbums.toggle()
                        if !isSelectingAlbums { albumSelection.removeAll() }
                    } label: {
                        isSelectingAlbums ? LT("library.done") : LT("library.select")
                    }
                    .help(isSelectingAlbums ? LS("library.closeSelection") : LS("library.selectMultipleAlbums"))
                }
            }
            ToolbarItem {
                if client.isSyncing {
                    Button(LS("library.cancel"), role: .cancel) { client.cancelSync() }
                } else {
                    Button { client.startSync() } label: {
                        Label(LS("library.syncLibrary"), systemImage: "arrow.clockwise")
                    }
                    .disabled(!client.connectionState.isConnected)
                }
            }
            #if os(iOS)
            // Without an edit toggle, `List(selection:)` can't enter multi-select
            // on touch, leaving the Speel/Wachtrij/Bewaar bar unreachable.
            if viewMode == .tracks, !tracks.isEmpty {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton().accessibilityHint(LS("library.selectMultipleTracks"))
                }
            }
            #endif
        }
        .onChange(of: searchText) { _, _ in
            // No mode switch any more: the overview shows a combined result of
            // its own, so you can find an album without first knowing to go to
            // the album tab and typing it again.
            if !isSearchActive { unified = nil }
            isSearching = true
            searchTask?.cancel()
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if !Task.isCancelled { reloadContent() }
            }
        }
        .onChange(of: selectedTag) { _, _ in reloadTracks() }
        // Every sort now orders in SQL and paginates, so a change is a full reload.
        .onChange(of: sort) { _, _ in reloadTracks() }
        .onChange(of: viewMode) { _, _ in
            isSelectingAlbums = false
            albumSelection.removeAll()
            reloadContent()
        }
        .onChange(of: client.trackCount) { _, _ in reload() }
        .onAppear { reload() }
        .sheet(item: $infoTrack) { TrackInfoSheet(track: $0) }
        .similarTracksSheet(item: $similarSeed)
        .alert(LS("library.saveAsPlaylist"), isPresented: $showSaveSheet) {
            TextField(LS("library.playlistName"), text: $newPlaylistName)
            Button(LS("library.cancel"), role: .cancel) {}
            Button(LS("library.save")) {
                let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                client.savePlaylist(name: name, tracks: selectedRecords())
                newPlaylistName = ""
                selection.removeAll()
            }
        } message: {
            Text("Bewaar \(selection.count) geselecteerde track\(selection.count == 1 ? "" : "s") als lokale playlist.")
        }
    }

    // MARK: - Mode switcher + content

    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    /// Titles *and* icons overflow a compact iPhone width. Dropping the titles
    /// was the wrong half to drop: "Overzicht · Tracks · Albums · Artiesten" is
    /// 30 characters over four segments and fits, while the icon-only row read as
    /// a house, a list, a grid and two people — a vocabulary you have to learn
    /// before you can use the screen. Keep the words, drop the pictures.
    private var compactPicker: Bool { hSizeClass == .compact }
    #else
    private var compactPicker: Bool { false }
    #endif

    private var modePicker: some View {
        let picker = Picker(LS("recent.pivotLabel"), selection: $viewMode) {
            ForEach(ViewMode.allCases) { mode in
                Label(mode.label, systemImage: mode.icon).tag(mode)
            }
        }
        .pickerStyle(.segmented)

        return Group {
            if compactPicker {
                picker.labelStyle(.titleOnly)
            } else {
                picker.labelStyle(.titleAndIcon)
            }
        }
        .padding(.horizontal, Spacing.lg)
        .padding(.vertical, Spacing.sm)
    }

    private var searchPrompt: String {
        switch viewMode {
        case .overview: LS("library.searchOverview")
        case .tracks:  LS("library.searchTracks")
        case .albums:  LS("library.searchAlbums")
        case .artists: LS("library.searchArtists")
        }
    }

    /// The active mode's scroll view — kept as the view's root content (chrome lives
    /// in safe-area insets) so it inherits the tab's NowPlayingBar bottom inset.
    @ViewBuilder
    private var modeContent: some View {
        switch viewMode {
        // Searching from the overview no longer throws you into the track list:
        // the overview IS the combined result now (P7).
        case .overview:
            if isSearchActive { unifiedResults }
            else if searchOnly { searchIdle }
            else { overviewContent }
        case .tracks:  tracksContent
        case .albums:  albumsContent
        case .artists: artistsContent
        }
    }

    /// What the search tab shows before you've typed anything. Deliberately not
    /// the library overview: that's the Bibliotheek tab, and repeating it here
    /// would make the two tabs look like the same screen.
    private var searchIdle: some View {
        ContentUnavailableView {
            Label(LS("search.idleTitle"), systemImage: "magnifyingglass")
        } description: {
            LT("search.idleBody")
        }
    }

    private var isSearchActive: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    @ViewBuilder
    private var tracksContent: some View {
        if isLoadingTracks && displayTracks.isEmpty {
            SkeletonRows()
        } else if displayTracks.isEmpty && !client.isSyncing {
            emptyState
        } else {
            List(selection: $selection) {
                ForEach(Array(displayTracks.enumerated()), id: \.element.id) { index, track in
                    LibraryTrackRow(track: track, canPlay: client.hasActiveOutput) {
                        play([asRecord(track)])
                    }
                    .contextMenu { rowMenu(track) }
                    .tag(track.id)
                    .onAppear {
                        if index >= displayTracks.count - 8 { Task { await loadMoreTracks() } }
                    }
                }
                if loadingMore {
                    HStack { Spacer(); ProgressView(); Spacer() }
                }
            }
            .refreshable { await refresh() }
        }
    }

    /// Grid data after the favorites filter.
    private var visibleAlbums: [DatabaseManager.AlbumResult] {
        guard favoritesOnly else { return albums }
        return albums.filter { client.isFavoriteAlbum(album: $0.album, artist: $0.artist) }
    }

    private var visibleArtists: [DatabaseManager.ArtistResult] {
        guard favoritesOnly else { return artists }
        return artists.filter { client.isFavoriteArtist($0.name) }
    }

    @ViewBuilder
    private var albumsContent: some View {
        AsyncStateView(isLoading: isLoadingGrid, isEmpty: visibleAlbums.isEmpty,
                       onRetry: { reloadContent() }) {
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: Spacing.lg) {
                    ForEach(Array(visibleAlbums.enumerated()), id: \.element.id) { index, album in
                        Group {
                            if isSelectingAlbums {
                                Button { toggleAlbumSelection(album.albumKey) } label: {
                                    AlbumGridCell(album: album)
                                        .overlay(alignment: .topTrailing) { albumSelectionBadge(album.albumKey) }
                                }
                                .buttonStyle(.plain)
                            } else {
                                NavigationLink(value: album) { AlbumGridCell(album: album) }
                                    .buttonStyle(.plain)
                                    .contextMenu {
                                        Button { enterAlbumSelection(album.albumKey) } label: {
                                            Label(LS("library.selectMultiple"), systemImage: "checkmark.circle")
                                        }
                                        PlayActionsMenu(fetch: { [client] in
                                            await client.tracksForAlbum(album.albumKey).map(\.asTrackRecord)
                                        })
                                    }
                            }
                        }
                        .onAppear {
                            if index >= visibleAlbums.count - 6 { Task { await loadMoreAlbums() } }
                        }
                    }
                }
                .padding(Spacing.lg)
                if loadingMore {
                    ProgressView().padding(.bottom, Spacing.lg)
                }
            }
            .refreshable { await refresh() }
        } empty: {
            gridEmptyState(noun: "albums")
        }
    }

    @ViewBuilder
    private var artistsContent: some View {
        AsyncStateView(isLoading: isLoadingGrid, isEmpty: visibleArtists.isEmpty,
                       onRetry: { reloadContent() }) {
            ScrollView {
                LazyVGrid(columns: gridColumns, spacing: Spacing.lg) {
                    ForEach(Array(visibleArtists.enumerated()), id: \.element.id) { index, artist in
                        NavigationLink(value: artist) { ArtistGridCell(artist: artist) }
                            .buttonStyle(.plain)
                            .contextMenu {
                                PlayActionsMenu(fetch: { [client] in
                                    var records: [TrackRecord] = []
                                    for album in await client.albumsByArtist(artist.name) {
                                        records += await client.tracksForAlbum(album.albumKey).map(\.asTrackRecord)
                                    }
                                    return records
                                })
                            }
                            .onAppear {
                                if index >= visibleArtists.count - 6 { Task { await loadMoreArtists() } }
                            }
                    }
                }
                .padding(Spacing.lg)
                if loadingMore {
                    ProgressView().padding(.bottom, Spacing.lg)
                }
            }
            .refreshable { await refresh() }
        } empty: {
            gridEmptyState(noun: "artiesten")
        }
    }

    @ViewBuilder
    private func gridEmptyState(noun: String) -> some View {
        if client.connectionState.isConnected {
            ContentUnavailableView("Geen \(noun)", systemImage: "square.grid.2x2",
                description: Text(searchText.isEmpty ? "Synchroniseer je bibliotheek." : "Geen \(noun) voor “\(searchText)”."))
        } else {
            ContentUnavailableView(LS("library.notConnected"), systemImage: "wifi.slash",
                description: LT("library.connectFirst"))
        }
    }

    // MARK: - Selection action bar

    private var selectionBar: some View {
        HStack(spacing: Spacing.md) {
            LT("\(selection.count) geselecteerd").font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button { play(selectedRecords()) } label: { Label(LS("library.play"), systemImage: "play.fill") }
                .disabled(!client.hasActiveOutput)
            Button { queue(selectedRecords()) } label: { Label(LS("nav.queue"), systemImage: "text.append") }
                .disabled(!client.hasActiveOutput)
            Button { showSaveSheet = true } label: { Label(LS("library.save"), systemImage: "plus.rectangle.on.folder") }
            Button { selection.removeAll() } label: { Label(LS("library.clear"), systemImage: "xmark") }
                .labelStyle(.iconOnly)
        }
        .padding(.horizontal, Spacing.lg).padding(.vertical, Spacing.sm)
        .background(.bar)
        .transition(.move(edge: .bottom))
    }

    // MARK: - Album multi-select

    private var albumSelectionBar: some View {
        HStack(spacing: Spacing.md) {
            Text("\(albumSelection.count) album\(albumSelection.count == 1 ? "" : "s")")
                .font(.callout).foregroundStyle(.secondary)
            Spacer()
            Button { bulkPlayAlbums() } label: { Label(LS("library.playAll"), systemImage: "play.fill") }
                .disabled(!client.hasActiveOutput)
            Button { bulkQueueAlbums() } label: { Label(LS("library.addToQueue"), systemImage: "text.append") }
                .disabled(!client.hasActiveOutput)
            Button { albumSelection.removeAll() } label: { Label(LS("library.clear"), systemImage: "xmark") }
                .labelStyle(.iconOnly)
        }
        .padding(.horizontal, Spacing.lg).padding(.vertical, Spacing.sm)
        .background(.bar)
        .transition(.move(edge: .bottom))
    }

    /// Selection order = tap order (append/remove), so the bulk queue matches it.
    private func toggleAlbumSelection(_ key: String) {
        if let i = albumSelection.firstIndex(of: key) { albumSelection.remove(at: i) }
        else { albumSelection.append(key) }
    }

    private func enterAlbumSelection(_ key: String) {
        isSelectingAlbums = true
        if !albumSelection.contains(key) { albumSelection.append(key) }
    }

    @ViewBuilder
    private func albumSelectionBadge(_ key: String) -> some View {
        let selected = albumSelection.contains(key)
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(selected ? Color.roonGold : Color.white.opacity(0.8))
            .padding(6)
            .shadow(radius: 2)
    }

    private func bulkPlayAlbums() {
        Haptics.tap()
        let keys = albumSelection
        Task { await client.playAlbums(albumKeys: keys) }
        exitAlbumSelection()
    }

    private func bulkQueueAlbums() {
        Haptics.tap()
        let keys = albumSelection
        Task { await client.queueAlbums(albumKeys: keys) }
        exitAlbumSelection()
    }

    private func exitAlbumSelection() {
        isSelectingAlbums = false
        albumSelection.removeAll()
    }

    // MARK: - Per-row context menu

    @ViewBuilder
    private func rowMenu(_ track: DatabaseManager.LibraryTrackRow) -> some View {
        let rec = asRecord(track)
        PlayActionsMenu(fetch: { [rec] })
        Divider()
        Button("Start Sonic Radio") {
            Task { await client.playSonicRadio(title: track.title, artist: track.artist, album: track.album) }
        }.disabled(!client.hasActiveOutput)
        Button(LS("library.sonicallySimilar"), systemImage: "waveform.path.ecg") {
            similarSeed = SonicSeed(title: track.title, artist: track.artist,
                                    album: track.album, imageKey: track.imageKey)
        }
        Divider()
        Button("Info", systemImage: "info.circle") { infoTrack = track }
        Button(LS("library.saveAsPlaylistMenu")) {
            selection = [track.id]
            showSaveSheet = true
        }
    }

    // MARK: - Helpers

    private func asRecord(_ t: DatabaseManager.LibraryTrackRow) -> TrackRecord {
        TrackRecord(id: t.id, title: t.title, artist: t.artist, album: t.album,
                    year: t.year, isLive: t.isLive, imageKey: t.imageKey)
    }

    private func selectedRecords() -> [TrackRecord] {
        displayTracks.filter { selection.contains($0.id) }.map(asRecord)
    }

    private func play(_ tracks: [TrackRecord]) {
        guard !tracks.isEmpty else { return }
        Haptics.tap()
        // Follow the active output: on-device when "dit apparaat" is chosen, else
        // the selected Roon zone (identical to the old curateTracks path). Queue +
        // Sonic Radio stay zone-only — there's no local equivalent.
        Task { await client.playToActiveOutput(tracks) }
    }

    private func queue(_ tracks: [TrackRecord], next: Bool = false) {
        guard !tracks.isEmpty else { return }
        Haptics.tap()
        Task { await client.queueToActiveOutput(tracks, next: next) }
    }

    private var tagChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(tags, id: \.tag) { item in
                    let isOn = selectedTag == item.tag
                    Button {
                        selectedTag = isOn ? nil : item.tag
                    } label: {
                        Text(item.tag)
                            .font(.caption)
                            .padding(.horizontal, 9).padding(.vertical, Spacing.xs)
                            .background(isOn ? Color.roonGold : Color.platformQuaternaryFill.opacity(0.5),
                                        in: Capsule())
                            // Gold is a light colour — white on gold fails WCAG AA (~2.3:1).
                            .foregroundStyle(isOn ? .black : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, Spacing.sm)
        }
        .background(.bar)
    }

    private func reload() {
        overviewLoaded = false   // a resync (trackCount change) should repopulate the overview
        Task { tags = await client.topTags(limit: 28) }
        Task { await client.ensureFavoritesLoaded() }   // drives the star filter
        reloadContent()
    }

    /// Loads data for whichever browse mode is active.
    private func reloadContent() {
        switch viewMode {
        case .overview:
            if isSearchActive {
                loadUnified()
            } else {
                // `loadOverview` returns early once loaded, so it can't be the
                // one to clear the spinner — clearing the search box would leave
                // it turning forever. (Couldn't happen before: searching used to
                // switch you to the track list, whose reload always cleared it.)
                isSearching = false
                loadOverview()
            }
        case .tracks:  reloadTracks()
        case .albums:  loadAlbums()
        case .artists: loadArtists()
        }
    }

    // MARK: - Tracks (paginated, endless scroll)

    /// Sorts ordered in SQL → offset pagination. Random + play-stat sorts are
    /// single-shot (naturally bounded), so they don't paginate.
    private func isPaginable(_ sort: SortField) -> Bool {
        switch sort {
        case .random, .mostPlayed, .recentlyPlayed: false
        default: true
        }
    }

    private func browseOrder(for sort: SortField) -> DatabaseManager.BrowseOrder {
        switch sort {
        case .title:         .title
        case .artist:        .artist
        case .album:         .album
        case .year:          .year
        case .bpm:           .bpm
        case .recentlyAdded: .recentlyAdded
        case .random, .mostPlayed, .recentlyPlayed: .artist   // unused (single-shot)
        }
    }

    private func reloadTracks() {
        tracks = []
        displayTracks = []
        seenTrackKeys = []
        tracksReachedEnd = false
        isLoadingTracks = true
        Task { await loadTracksPage() }
    }

    private func loadMoreTracks() async {
        guard isPaginable(sort), !tracksReachedEnd, !loadingMore else { return }
        loadingMore = true
        await loadTracksPage()
        loadingMore = false
    }

    /// Loads and appends one page for the active sort. Dedupes artist+title
    /// incrementally across pages (so remasters/duplicate editions don't repeat)
    /// while the SQL order stays stable for consistent paging.
    private func loadTracksPage() async {
        let q = searchText, tag = selectedTag, currentSort = sort
        if !isPaginable(currentSort) {
            let rows = await fetchBoundedTracks(query: q, tag: tag, sort: currentSort)
            let display = await Task.detached { Self.sortAndDedupe(rows, by: currentSort) }.value
            guard currentSort == sort, q == searchText, tag == selectedTag else { return }
            tracks = rows
            displayTracks = display
            tracksReachedEnd = true
            isLoadingTracks = false
            isSearching = false
            return
        }
        let page = await client.browseTracks(query: q, tag: tag, limit: pageSize,
                                             order: browseOrder(for: currentSort), offset: tracks.count)
        // Drop a page whose request no longer matches the current query/tag/sort.
        guard currentSort == sort, q == searchText, tag == selectedTag else { return }
        var appended: [DatabaseManager.LibraryTrackRow] = []
        for r in page {
            let key = "\(r.artist?.lowercased() ?? "")|\(r.title.lowercased())"
            if seenTrackKeys.insert(key).inserted { appended.append(r) }
        }
        tracks.append(contentsOf: page)
        displayTracks.append(contentsOf: appended)
        if page.count < pageSize { tracksReachedEnd = true }
        isLoadingTracks = false
        isSearching = false
        // A page that fully deduped away would otherwise stall the scroll trigger.
        if appended.isEmpty, !tracksReachedEnd { await loadTracksPage() }
    }

    /// Single-shot fetch for the non-paginable sorts: play-stat ranking (bounded by
    /// history) and random (a bounded shuffle).
    private func fetchBoundedTracks(query: String, tag: String?, sort: SortField) async -> [DatabaseManager.LibraryTrackRow] {
        switch sort {
        case .mostPlayed, .recentlyPlayed:
            let stats = await client.playStats()
            let ranked = sort == .mostPlayed
                ? stats.sorted { $0.count > $1.count }
                : stats.sorted { $0.lastPlayed > $1.lastPlayed }
            let keys = ranked.lazy.map(\.matchKey).filter { !$0.isEmpty }
            var rows = await client.tracksByMatchKeys(Array(keys.prefix(400)))
            if !query.isEmpty {
                let needle = query.lowercased()
                rows = rows.filter {
                    $0.title.lowercased().contains(needle)
                        || ($0.artist ?? "").lowercased().contains(needle)
                        || ($0.album ?? "").lowercased().contains(needle)
                }
            }
            if let tag, !tag.isEmpty {
                let t = tag.lowercased()
                rows = rows.filter { $0.tags.contains { $0.lowercased() == t } }
            }
            return Array(rows.prefix(300))
        default:   // .random — a bounded shuffle window
            return await client.browseTracks(query: query, tag: tag, limit: 500)
        }
    }

    // MARK: - Albums / Artists grids (paginated, endless scroll)

    private func loadAlbums() {
        albums = []
        albumsReachedEnd = false
        isLoadingGrid = true
        Task { await loadAlbumsPage() }
    }

    private func loadMoreAlbums() async {
        // The favorites filter is client-side over loaded pages, so pause paging there.
        guard !albumsReachedEnd, !loadingMore, !favoritesOnly else { return }
        loadingMore = true
        await loadAlbumsPage()
        loadingMore = false
    }

    private func loadAlbumsPage() async {
        let q = searchText
        let page = await client.searchAlbums(query: q, limit: gridPageSize, offset: albums.count)
        guard q == searchText else { return }
        albums.append(contentsOf: page)
        if page.count < gridPageSize { albumsReachedEnd = true }
        isLoadingGrid = false
        isSearching = false
    }

    private func loadArtists() {
        artists = []
        artistsReachedEnd = false
        isLoadingGrid = true
        Task { await loadArtistsPage() }
    }

    private func loadMoreArtists() async {
        guard !artistsReachedEnd, !loadingMore, !favoritesOnly else { return }
        loadingMore = true
        await loadArtistsPage()
        loadingMore = false
    }

    private func loadArtistsPage() async {
        let q = searchText
        let page = await client.searchArtists(query: q, limit: gridPageSize, offset: artists.count)
        guard q == searchText else { return }
        artists.append(contentsOf: page)
        if page.count < gridPageSize { artistsReachedEnd = true }
        isLoadingGrid = false
        isSearching = false
    }

    /// Pull-to-refresh: reset the active mode's pagination and reload the first page.
    private func refresh() async {
        tags = await client.topTags(limit: 28)
        switch viewMode {
        case .overview:
            await refreshOverview()
        case .tracks:
            tracks = []; displayTracks = []; seenTrackKeys = []; tracksReachedEnd = false
            await loadTracksPage()
        case .albums:
            albums = []; albumsReachedEnd = false
            await loadAlbumsPage()
        case .artists:
            artists = []; artistsReachedEnd = false
            await loadArtistsPage()
        }
    }

    @ViewBuilder
    var emptyState: some View {
        if client.connectionState.isConnected {
            ContentUnavailableView(LS("library.noMatchingTracks"), systemImage: "music.note.list",
                description: selectedTag != nil ? LT("Geen tracks met tag “\(selectedTag!)”.") : LT("library.syncThenSearch"))
        } else {
            ContentUnavailableView(LS("library.notConnected"), systemImage: "wifi.slash",
                description: LT("library.connectFirst"))
        }
    }

    // MARK: - Combined search results

    /// One search box, all three kinds at once (readiness P7).
    ///
    /// Before this, typing in the overview jumped you to the track list, so
    /// finding an *album* meant knowing to switch to the album tab first and
    /// search again. Three separate audits called that out. The sections are
    /// capped at five and re-ranked by `UnifiedSearch` — see there for why the
    /// alphabetical SQL order made a naive cap actively wrong.
    @ViewBuilder
    private var unifiedResults: some View {
        if isSearching && unified == nil {
            SkeletonRows()
        } else if let unified, unified.isEmpty {
            ContentUnavailableView {
                Label(LS("search.noResultsTitle"), systemImage: "magnifyingglass")
            } description: {
                Text(String(format: LS("search.noResultsBody"), searchText))
            } actions: {
                // A literal miss is exactly when the sonic engine is worth
                // trying — "dreamy late-night piano" matches no title anywhere.
                sonicHandoff
            }
        } else if let unified {
            List {
                if !unified.artists.isEmpty {
                    Section(LS("bm.section.artists")) {
                        ForEach(unified.artists) { artist in
                            NavigationLink(value: artist) { searchRow(
                                artist.imageKey, title: artist.name, subtitle: artistSubtitle(artist),
                                circular: true) }
                        }
                        showAllRow(.artists, shown: unified.artists.count)
                    }
                }
                if !unified.albums.isEmpty {
                    Section(LS("bm.section.albums")) {
                        ForEach(unified.albums) { album in
                            NavigationLink(value: album) { searchRow(
                                album.imageKey, title: album.album, subtitle: albumSubtitle(album)) }
                        }
                        showAllRow(.albums, shown: unified.albums.count)
                    }
                }
                if !unified.tracks.isEmpty {
                    Section(LS("library.tracks")) {
                        ForEach(unified.tracks, id: \.id) { track in
                            Button {
                                play([track])
                            } label: {
                                searchRow(track.imageKey, title: track.title,
                                          subtitle: trackSubtitle(track))
                            }
                            .buttonStyle(.plain)
                            .disabled(!client.hasActiveOutput)
                            .contextMenu { PlayActionsMenu(fetch: { [track] }) }
                        }
                        showAllRow(.tracks, shown: unified.tracks.count)
                    }
                }
                Section { sonicHandoff }
            }
            .listStyle(.plain)
        }
    }

    /// The same words, handed to the CLAP engine. `SonicSearchView` was a
    /// separate door you had to know about and retype into; now the library's
    /// search box opens it pre-filled and it runs on appear.
    private var sonicHandoff: some View {
        NavigationLink {
            SonicSearchView(initialQuery: searchText)
        } label: {
            Label(String(format: LS("search.trySonic"), searchText), systemImage: "sparkle.magnifyingglass")
                .font(.subheadline)
        }
    }

    /// "Toon alles" — the combined view answers "which did you mean"; the
    /// per-kind screen has the full list, with the query carried over.
    ///
    /// Only when the section filled up, because a capped section is the only
    /// case where results may be hidden. Offering "show all albums" under a
    /// single album is the kind of pointless chrome this screen was just
    /// cleaned of.
    @ViewBuilder
    private func showAllRow(_ mode: ViewMode, shown: Int) -> some View {
        if shown >= UnifiedSearch.sectionLimit {
            showAllButton(mode)
        }
    }

    private func showAllButton(_ mode: ViewMode) -> some View {
        Button { viewMode = mode } label: {
            HStack {
                Text(String(format: LS("search.showAll"), mode.label.lowercased()))
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            .font(.subheadline)
        }
    }

    private func searchRow(_ imageKey: String?, title: String, subtitle: String,
                           circular: Bool = false) -> some View {
        HStack(spacing: Spacing.md) {
            AlbumArtView(imageKey: imageKey, size: 44, cornerRadius: circular ? 22 : Radius.sm)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(subtitle.isEmpty ? title : "\(title), \(subtitle)")
    }

    private func artistSubtitle(_ a: DatabaseManager.ArtistResult) -> String {
        "\(a.albumCount) album\(a.albumCount == 1 ? "" : "s") · \(a.trackCount) \(LS("library.tracks").lowercased())"
    }

    private func albumSubtitle(_ album: DatabaseManager.AlbumResult) -> String {
        var parts: [String] = []
        if let a = album.artist, !a.isEmpty { parts.append(a) }
        if let y = album.year { parts.append(String(y)) }
        return parts.joined(separator: " · ")
    }

    private func trackSubtitle(_ t: TrackRecord) -> String {
        [t.artist, t.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    /// Runs the combined query. Guarded on the query text so a slow read for an
    /// older keystroke can't overwrite the results of a newer one.
    private func loadUnified() {
        let q = searchText
        guard !q.trimmingCharacters(in: .whitespaces).isEmpty else {
            unified = nil
            isSearching = false
            return
        }
        Task {
            let results = await client.searchEverything(query: q)
            guard q == searchText else { return }
            unified = results
            isSearching = false
        }
    }

    // MARK: - Overview landing

    /// The library landing: a stats hero, recently-added / recently-played shelves,
    /// "voor jou" recommendation shelves, and browse-by tiles. A List-as-feed (like
    /// DiscoveryView) lazily hosts the shelves and dodges the iOS 26 NavigationStack
    /// + custom-ScrollView layout bug.
    @ViewBuilder
    private var overviewContent: some View {
        List {
            if let stats {
                statsHero(stats).plainCardRow()
                if !recentlyAdded.isEmpty {
                    trackShelf(LS("library.recentlyAdded"), "clock.badge.plus", recentlyAdded).plainCardRow()
                }
                if !recentPlayed.isEmpty {
                    trackShelf(LS("library.recentlyPlayedShelf"), "play.circle", recentPlayed).plainCardRow()
                }
                if forgotten.count > 1 {
                    recordShelf(LS("library.forgottenFavorites"), "clock.arrow.circlepath", forgotten).plainCardRow()
                }
                browseTiles.plainCardRow()
                // Downloads lived only in Settings, which is where you go to
                // configure things — not to find your music. Same navCard shape
                // as the other destinations, so it costs no extra shelf.
                if !client.offlineKeys.isEmpty {
                    navCard(LS("downloads.sectionTitle"),
                            String(format: LS("downloads.librarySubtitle"), client.offlineKeys.count),
                            "arrow.down.circle") { DownloadsView() }.plainCardRow()
                }
                // Playlists and bookmarks used to hang under the "Maak" tab —
                // a list that linked to a hub. They're collections, so they
                // belong with the rest of your music, in the same navCard shape
                // the downloads already use.
                navCard(LS("root.savedPlaylists"), LS("library.playlistsSubtitle"),
                        SidebarItem.playlists.icon) { PlaylistsView() }.plainCardRow()
                navCard(LS("root.savedForLater"), LS("library.bookmarksSubtitle"),
                        SidebarItem.bookmarks.icon) { BookmarksView() }.plainCardRow()
                navCard(LS("library.discoverWeeklyTitle"),
                        LS("library.discoverWeeklySubtitle"),
                        "sparkles") { DiscoverWeeklyView() }.plainCardRow()
                navCard(LS("library.myRadiosTitle"), LS("library.myRadiosSubtitle"),
                        "dot.radiowaves.left.and.right") { CustomRadioView() }.plainCardRow()
                navCard(LS("nav.recommend"), LS("library.recommendSubtitle"),
                        "wand.and.stars") { RecommendView() }.plainCardRow()
                // Last, because it's the one you open on purpose rather than
                // while looking for something to play.
                navCard(LS("nav.lab"), LS("library.labSubtitle"),
                        "flask") { LabView() }.plainCardRow()
            } else if !overviewLoaded {
                SkeletonRows().plainCardRow()
            } else {
                overviewEmpty.plainCardRow()
            }
        }
        .listStyle(.plain)
        .refreshable { await refreshOverview() }
    }

    // MARK: Overview — hero + shelves

    /// One quiet line instead of six dashboard pieces.
    ///
    /// This used to be three large number cards plus three chips (top genre,
    /// hours of music, % analysed) — a dashboard standing between you and your
    /// music, on the screen you open to find something to play. The numbers are
    /// still true, they just don't need to be the first thing you see.
    private func statsHero(_ stats: DatabaseManager.LibraryStats) -> some View {
        var parts = ["\(stats.totalTracks.formatted()) \(LS("library.tracks").lowercased())",
                     "\(stats.totalAlbums.formatted()) \(LS("bm.section.albums").lowercased())"]
        if analyzedTotal > 0 {
            parts.append("\(analyzedMatched * 100 / analyzedTotal)% \(LS("library.analysedSuffix"))")
        }
        return Text(parts.joined(separator: " · "))
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func trackShelf(_ title: String, _ icon: String,
                            _ rows: [DatabaseManager.LibraryTrackRow]) -> some View {
        shelf(title, icon, covers: rows.map(trackCover),
              zoneAvailable: client.hasActiveOutput) { EmptyView() }
    }

    private func recordShelf(_ title: String, _ icon: String, _ recs: [TrackRecord]) -> some View {
        shelf(title, icon, covers: recs.map(recordCover),
              zoneAvailable: client.hasActiveOutput) { EmptyView() }
    }

    private func albumShelf(_ title: String, _ icon: String,
                            _ albums: [DatabaseManager.AlbumResult]) -> some View {
        shelf(title, icon, covers: albums.map(albumCover),
              zoneAvailable: client.hasActiveOutput) { EmptyView() }
    }

    private func trackCover(_ t: DatabaseManager.LibraryTrackRow) -> Cover {
        let rec = asRecord(t)
        return Cover(id: t.id, title: t.title, subtitle: t.artist, imageKey: t.imageKey) {
            Task { await client.playToActiveOutput([rec]) }
        }
    }

    private func recordCover(_ t: TrackRecord) -> Cover {
        Cover(id: t.id, title: t.title, subtitle: t.artist, imageKey: t.imageKey) {
            Task { await client.playToActiveOutput([t]) }
        }
    }

    private func albumCover(_ a: DatabaseManager.AlbumResult) -> Cover {
        Cover(id: a.albumKey, title: a.album, subtitle: a.artist, imageKey: a.imageKey) {
            Task { await client.playAlbum(albumKey: a.albumKey) }
        }
    }


    // MARK: Overview — browse by genre / sfeer / decade

    /// Tappable tiles that deep-link into a filtered library list. Genres + decades
    /// come from `radioFacetOptions()`; "sfeer" reuses the audio-tag vocabulary
    /// (`topTags`) — the CLAP moods aren't a `FilterOptions` dimension, the tags are.
    @ViewBuilder
    private var browseTiles: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionHeader(LS("library.browseBy"), "square.grid.2x2") { EmptyView() }
            if let facets, !facets.genres.isEmpty {
                filterChipRow(LS("library.genres"), facets.genres.prefix(16).map {
                    LibraryFilter(kind: .genre($0.key), title: $0.label.capitalized)
                })
            }
            if !tags.isEmpty {
                filterChipRow(LS("library.mood"), tags.prefix(16).map {
                    LibraryFilter(kind: .tag($0.tag), title: $0.tag.capitalized)
                })
            }
            if let facets, !facets.decades.isEmpty {
                filterChipRow(LS("library.decades"), facets.decades.map {
                    LibraryFilter(kind: .decade($0), title: "\($0)s")
                })
            }
        }
    }

    private func filterChipRow(_ heading: String, _ filters: [LibraryFilter]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(heading).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.sm) {
                    ForEach(filters, id: \.self) { filter in
                        NavigationLink(value: filter) {
                            Label(filter.title, systemImage: filter.icon)
                                .labelStyle(.titleAndIcon)
                                .font(.caption)
                                .padding(.horizontal, 12).padding(.vertical, 7)
                                .background(Color.platformQuaternaryFill.opacity(0.5), in: Capsule())
                                .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 2)
            }
        }
    }

    // MARK: Overview — Ontdek Wekelijks entry + states

    /// A prominent navigation card into another feature (Ontdek Wekelijks, Mijn
    /// radio's, Aanbevelen) — pushed onto this stack so it works on iOS + macOS alike.
    @ViewBuilder
    private func navCard<Destination: View>(
        _ title: String, _ subtitle: String, _ icon: String,
        @ViewBuilder destination: @escaping () -> Destination
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: icon)
                    .font(.title2).foregroundStyle(Color.roonGold)
                    .frame(width: 44, height: 44)
                    .background(Color.roonGold.opacity(0.15), in: RoundedRectangle(cornerRadius: Radius.lg))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                // No manual chevron: this NavigationLink lives in a List, which
                // already draws its own disclosure indicator (double ">  >").
            }
            .padding(Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var overviewEmpty: some View {
        ContentUnavailableView(
            client.connectionState.isConnected ? LS("library.noLibraryYet") : LS("library.notConnected"),
            systemImage: client.connectionState.isConnected ? "music.note.house" : "wifi.slash",
            description: client.connectionState.isConnected
                ? LT("library.syncToFillOverview")
                : LT("library.connectFirst"))
    }

    // MARK: Overview — data loading

    private func loadOverview() {
        guard !overviewLoaded else { return }
        overviewLoaded = true
        Task { await performOverviewLoad() }
    }

    private func refreshOverview() async {
        overviewLoaded = true   // keep the onChange guard from double-firing mid-refresh
        await performOverviewLoad()
    }

    /// Stats first (drives the hero + progressive reveal), then the shelves concurrently.
    private func performOverviewLoad() async {
        async let statsV = client.libraryStats()
        async let analyzedV = client.audioFeaturesStats()
        async let durationV = client.libraryDurationSeconds()
        async let addedV = client.browseTracks(query: "", tag: nil, order: .recentlyAdded)
        async let playedV = recentPlayedRows()
        async let forgottenV = client.forgottenFavorites()
        async let facetsV = client.radioFacetOptions()

        stats = await statsV
        let a = await analyzedV
        analyzedTotal = a.total
        analyzedMatched = a.matched
        librarySeconds = await durationV
        recentlyAdded = Array(await addedV.prefix(15))
        recentPlayed = await playedV
        forgotten = await forgottenV
        facets = await facetsV
    }

    /// Recently-played rows *with artwork*: `ListenEntry` carries no image, so rank the
    /// play stats by last-played and resolve the top keys to full library rows.
    private func recentPlayedRows() async -> [DatabaseManager.LibraryTrackRow] {
        let ps = await client.playStats()
        let keys = ps.sorted { $0.lastPlayed > $1.lastPlayed }
            .map(\.matchKey).filter { !$0.isEmpty }
        return await client.tracksByMatchKeys(Array(keys.prefix(15)))
    }
}

// MARK: - Sync progress banner

@MainActor
struct SyncProgressBanner: View {
    @Environment(RoonClient.self) private var client

    public var body: some View {
        let progress = client.syncProgress
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                ProgressView(value: progress.fraction).progressViewStyle(.linear)
                Text("\(progress.albumsCompleted)/\(progress.albumsTotal)")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    .frame(width: 80, alignment: .trailing)
            }
            Text(progress.phase).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.horizontal, Spacing.lg).padding(.vertical, Spacing.sm)
        .background(.regularMaterial)
    }
}

// MARK: - Track row (with audio features)

/// `@MainActor` is explicit here, not inferred: `isDownloaded` below is a plain
/// computed property, not `body`, so it does not get the isolation SwiftUI gives
/// `body` by protocol. Without the annotation it reads main-actor state from a
/// nonisolated context — which my local Swift (6.3.2) accepts and the CI runner's
/// older toolchain rejects. Annotate any view that touches client state outside
/// `body`; local builds cannot be trusted to catch it.
@MainActor
struct LibraryTrackRow: View {
    @Environment(RoonClient.self) private var client
    let track: DatabaseManager.LibraryTrackRow
    let canPlay: Bool
    let onPlay: () -> Void

    /// Downloaded rows carry a small mark. Read from the in-memory key set, not
    /// the filesystem — a list must never stat per row.
    private var isDownloaded: Bool {
        client.offlineKeys.contains(LocalPlayability.matchKey(for: asRecordStatic(track)))
    }

    private func asRecordStatic(_ t: DatabaseManager.LibraryTrackRow) -> TrackRecord {
        TrackRecord(id: t.id, title: t.title, artist: t.artist, album: t.album,
                    year: t.year, isLive: t.isLive, imageKey: t.imageKey)
    }

    public var body: some View {
        HStack(spacing: 10) {
            AlbumArtView(imageKey: track.imageKey, size: 40)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(track.title).font(.body).lineLimit(1)
                    if track.isLive {
                        Text("LIVE").font(.caption2.bold()).foregroundStyle(Color.roonWarning)
                    }
                    if let y = track.year {
                        Text(String(y)).font(.caption).foregroundStyle(.tertiary)
                    }
                    if isDownloaded {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(Color.roonGold)
                            .accessibilityLabel(LS("downloads.availableOffline"))
                    }
                }
                HStack(spacing: 6) {
                    if let a = track.artist {
                        Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let bpm = track.bpm {
                        badge("\(Int(bpm)) BPM")
                    }
                    if let cam = track.camelot, !cam.isEmpty {
                        badge(cam)
                    }
                    if !track.tags.isEmpty {
                        Text(track.tags.prefix(3).joined(separator: " · "))
                            .font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityText)
            Spacer()
            Button(action: onPlay) { Image(systemName: "play.fill") }
                .buttonStyle(.borderless)
                .disabled(!canPlay)
                .accessibilityLabel(LS("bm.playNow"))
                .help(canPlay ? LS("bm.playNow") : LS("library.chooseZoneFirst"))
        }
        .padding(.vertical, 2)
    }

    /// One coherent VoiceOver announcement per row instead of 4–7 separate atoms.
    private var accessibilityText: String {
        var parts: [String] = [track.title]
        if let a = track.artist, !a.isEmpty { parts.append(a) }
        if track.isLive { parts.append("live") }
        if let y = track.year { parts.append(String(y)) }
        if let bpm = track.bpm { parts.append("\(Int(bpm)) BPM") }
        return parts.joined(separator: ", ")
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(.quaternary, in: Capsule())
            .foregroundStyle(.secondary)
    }
}

// MARK: - Album grid cell

struct AlbumGridCell: View {
    let album: DatabaseManager.AlbumResult

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            AlbumArtView(imageKey: album.imageKey, size: 150, cornerRadius: Radius.lg)
            Text(album.album).font(.callout).lineLimit(1)
            Text(albumSubtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(albumSubtitle.isEmpty ? album.album : "\(album.album), \(albumSubtitle)")
    }

    private var albumSubtitle: String {
        var parts: [String] = []
        if let a = album.artist, !a.isEmpty { parts.append(a) }
        if let y = album.year { parts.append(String(y)) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Artist grid cell

struct ArtistGridCell: View {
    let artist: DatabaseManager.ArtistResult

    var body: some View {
        VStack(spacing: 6) {
            AlbumArtView(imageKey: artist.imageKey, size: 150, cornerRadius: 75)
            Text(artist.name).font(.callout).lineLimit(1)
            Text("\(artist.albumCount) album\(artist.albumCount == 1 ? "" : "s") · \(artist.trackCount) nummers")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(artist.name), \(artist.albumCount) album\(artist.albumCount == 1 ? "" : "s"), \(artist.trackCount) nummers")
    }
}
