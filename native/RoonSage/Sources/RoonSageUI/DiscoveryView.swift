import SwiftUI
import Charts
import RoonSageCore

/// Editorial "Listen Now"-style discovery: a hero rediscover card, cover-forward
/// shelves, and Swift Charts for the library breakdown — instead of stacked
/// grey text cards.
///
/// Built on `List` used as a (correctly width-clamped, lazily-loaded) vertical
/// feed of self-styled cards — each row strips the default List chrome via
/// `.plainCardRow()` so the cards read exactly as before, just hosted in a
/// container that doesn't fall over to the iOS 26 NavigationStack layout bug a
/// custom ScrollView did. See `GenerateView` for the full story.
@MainActor
public struct DiscoveryView: View {
    public init() {}
    @Environment(RoonClient.self) private var client
    @State private var stats: DatabaseManager.LibraryStats?
    @State private var undiscovered: [DatabaseManager.AlbumResult] = []   // "nog niet gehoord" (never-played)
    @State private var dormant: [DatabaseManager.AlbumResult] = []        // "weer opzetten" (recency-decay forgotten)
    @State private var albumOfDay: DatabaseManager.AlbumResult?           // deterministic daily pick
    @State private var forgotten: [TrackRecord] = []
    @State private var topTracks: [TrackRecord] = []
    // Cross-feature de-dup: what the weekly already surfaces, so these owned-music
    // shelves don't echo it (the "every Ontdek feature shows the same list" problem).
    @State private var weeklyAlbums: Set<String> = []
    @State private var weeklyTracks: Set<String> = []
    @State private var isLoaded = false
    @State private var actionMessage: String?   // transient "Afspelen gestart…" banner

    public var body: some View {
        List {
            ZoneHintBanner().plainCardRow()
            weeklyInstap.plainCardRow()
            labelsInstap.plainCardRow()
            if let stats {
                if let hero = heroItem { heroCard(hero).plainCardRow() }
                summaryCards(stats).plainCardRow()
                if let aotd = albumOfDay { albumOfDayCard(aotd).plainCardRow() }
                if !undiscovered.isEmpty {
                    shelf(LS("discovery.shelfNeverHeard"),
                          covers: undiscovered.map(albumCover),
                          zoneAvailable: client.hasActiveOutput) {
                        Button { Task {
                            undiscovered = await client.neverPlayedAlbums()
                                .filter { !weeklyAlbums.contains($0.album.lowercased()) }
                        } } label: {
                            Image(systemName: "shuffle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(LS("discovery.showAnotherSelection"))
                    }
                    .plainCardRow()
                }
                if !dormant.isEmpty {
                    shelf(LS("discovery.shelfPlayAgain"),
                          covers: dormant.map(albumCover),
                          zoneAvailable: client.hasActiveOutput) {
                        Button { Task {
                            dormant = await client.forgottenAlbums()
                                .filter { !weeklyAlbums.contains($0.album.lowercased()) }
                        } } label: {
                            Image(systemName: "shuffle")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(LS("discovery.showOtherForgottenAlbums"))
                    }
                    .plainCardRow()
                }
                if !topTracks.isEmpty {
                    shelf(LS("discovery.shelfTopTracks"),
                          covers: topTracks.map(trackCover),
                          zoneAvailable: client.hasActiveOutput) {
                        playAllButton(topTracks)
                    }
                    .plainCardRow()
                }
                if forgotten.count > 1 {
                    shelf(LS("discovery.shelfForgottenFavorites"),
                          covers: forgotten.dropFirst().map(trackCover),
                          zoneAvailable: client.hasActiveOutput) {
                        playAllButton(Array(forgotten))
                    }
                    .plainCardRow()
                }
                if !stats.tracksByDecade.isEmpty { decadeCard(stats).plainCardRow() }
                if !stats.topGenres.isEmpty { genreCard(stats).plainCardRow() }
            } else if !isLoaded {
                loadingState.plainCardRow()
            } else {
                emptyState.plainCardRow()
            }
        }
        .screenTitle(LS("discovery.title"))
        .toolbar {
            Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                .help(LS("discovery.refresh"))
                .accessibilityLabel(LS("discovery.refreshHint"))
        }
        .ambientSurface()
        .animation(Motion.standard, value: isLoaded)
        .overlay(alignment: .top) {
            if let actionMessage {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "play.circle.fill").foregroundStyle(Color.roonGold)
                    Text(actionMessage).font(.caption).lineLimit(2)
                }
                .padding(.horizontal, Spacing.md).padding(.vertical, Spacing.sm)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, Spacing.sm)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task(id: client.trackCount) { await load() }
    }

    // MARK: - "Ontdek Wekelijks" instap

    /// A prominent entry into the library-first weekly discovery playlist.
    private var weeklyInstap: some View {
        NavigationLink {
            DiscoverWeeklyView()
        } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: "sparkles")
                    .font(.title2)
                    .foregroundStyle(Color.roonGold)
                    .frame(width: 44, height: 44)
                    .background(Color.roonGold.opacity(0.15), in: RoundedRectangle(cornerRadius: Radius.lg))
                VStack(alignment: .leading, spacing: 2) {
                    LT("discovery.weeklyTitle").font(.headline)
                    LT("discovery.weeklySubtitle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                // No manual chevron: the List-hosted NavigationLink already draws
                // its own disclosure indicator (a second one read as ">  >").
            }
            .padding(Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Entry into browsing the library by record label.
    private var labelsInstap: some View {
        NavigationLink {
            LabelExplorerView()
        } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: "tag")
                    .font(.title2)
                    .foregroundStyle(Color.roonGold)
                    .frame(width: 44, height: 44)
                    .background(Color.roonGold.opacity(0.15), in: RoundedRectangle(cornerRadius: Radius.lg))
                VStack(alignment: .leading, spacing: 2) {
                    LT("discovery.labelsTitle").font(.headline)
                    LT("discovery.labelsSubtitle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(Spacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Hero "rediscover" card

    private struct HeroItem {
        let title: String
        let subtitle: String?
        let imageKey: String?
        let play: () -> Void
    }

    private var heroItem: HeroItem? {
        if let t = forgotten.first {
            return HeroItem(title: t.title, subtitle: t.artist, imageKey: t.imageKey) {
                Haptics.tap(); Task { await client.playToActiveOutput([t]) }
            }
        }
        if let a = dormant.first ?? undiscovered.first {
            return HeroItem(title: a.album, subtitle: a.artist, imageKey: a.imageKey) {
                Haptics.tap(); Task { await client.playAlbum(albumKey: a.albumKey) }
            }
        }
        return nil
    }

    private func heroCard(_ item: HeroItem) -> some View {
        HStack(spacing: Spacing.lg) {
            AlbumArtView(imageKey: item.imageKey, size: 120)
                .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
                .shadow(color: .roonShadow, radius: 10, y: 6)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Label(LS("discovery.rediscover"), systemImage: "sparkles")
                    .font(.caption.bold())
                    .foregroundStyle(Color.roonGold)
                Text(item.title).font(.title2.bold()).lineLimit(2)
                if let sub = item.subtitle {
                    Text(sub).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: Spacing.sm)
                HStack(spacing: Spacing.sm) {
                    Button {
                        Haptics.tap()
                        item.play()
                    } label: {
                        Label(LS("bm.playNow"), systemImage: "play.fill")
                            // Both spelled out because this button photographed
                            // as an EMPTY gold pill, and it took two fixes: the
                            // colour (it was the only prominent button in the app
                            // inheriting the app tint) and the label style —
                            // `Label` inside a button may fall back to icon-only,
                            // which is what was left after the colour was fixed.
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(.white)
                    }
                        // Every other prominent button in this app tints
                        // explicitly; these two were the only ones inheriting the
                        // app tint, and they photographed as an EMPTY gold pill —
                        // no text, no icon — on both hero cards. Stating the tint
                        // and the label colour makes the contrast independent of
                        // whatever the style derives from an inherited tint.
                        .buttonStyle(.borderedProminent)
                        .tint(Color.roonGold)
                        .disabled(!client.hasActiveOutput)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.lg)
        .background(
            LinearGradient(colors: [Color.roonGold.opacity(0.18), Color.roonGold.opacity(0.03)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: Radius.lg))
    }

    // MARK: - "Album van de dag"

    /// A once-a-day deterministic album pick (see `ForgottenMusicService.albumOfTheDay`).
    /// Mirrors the "Herontdek" hero styling but with a calendar label and album actions.
    private func albumOfDayCard(_ a: DatabaseManager.AlbumResult) -> some View {
        HStack(spacing: Spacing.lg) {
            AlbumArtView(imageKey: a.imageKey, size: 120)
                .clipShape(RoundedRectangle(cornerRadius: Radius.lg))
                .shadow(color: .roonShadow, radius: 10, y: 6)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Label(LS("discovery.albumOfDay"), systemImage: "calendar")
                    .font(.caption.bold())
                    .foregroundStyle(Color.roonGold)
                Text(a.album).font(.title2.bold()).lineLimit(2)
                if let sub = a.artist {
                    Text(sub).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: Spacing.sm)
                HStack(spacing: Spacing.sm) {
                    Button {
                        Haptics.tap()
                        Task { await client.playAlbum(albumKey: a.albumKey) }
                    } label: {
                        Label(LS("bm.playNow"), systemImage: "play.fill")
                            // Both spelled out because this button photographed
                            // as an EMPTY gold pill, and it took two fixes: the
                            // colour (it was the only prominent button in the app
                            // inheriting the app tint) and the label style —
                            // `Label` inside a button may fall back to icon-only,
                            // which is what was left after the colour was fixed.
                            .labelStyle(.titleAndIcon)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .foregroundStyle(.white)
                    }
                        // Every other prominent button in this app tints
                        // explicitly; these two were the only ones inheriting the
                        // app tint, and they photographed as an EMPTY gold pill —
                        // no text, no icon — on both hero cards. Stating the tint
                        // and the label colour makes the contrast independent of
                        // whatever the style derives from an inherited tint.
                        .buttonStyle(.borderedProminent)
                        .tint(Color.roonGold)
                        .disabled(!client.hasActiveOutput)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Spacing.lg)
        .background(
            LinearGradient(colors: [Color.roonGold.opacity(0.14), Color.roonGold.opacity(0.02)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: Radius.lg))
    }

    // MARK: - Cover shelves

    private func albumCover(_ a: DatabaseManager.AlbumResult) -> Cover {
        Cover(id: a.albumKey, title: a.album, subtitle: a.artist, imageKey: a.imageKey) {
            Haptics.tap(); Task { await client.playAlbum(albumKey: a.albumKey) }
        }
    }

    private func trackCover(_ t: TrackRecord) -> Cover {
        Cover(id: t.id, title: t.title, subtitle: t.artist, imageKey: t.imageKey) {
            Haptics.tap(); Task { await client.playToActiveOutput([t]) }
        }
    }

    private func playAllButton(_ tracks: [TrackRecord]) -> some View {
        HStack(spacing: Spacing.sm) {
            Button {
                Haptics.tap()
                Task { await client.playToActiveOutput(tracks) }
            } label: { Label(LS("discovery.playAll"), systemImage: "play.fill") }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!client.hasActiveOutput)
        }
    }

    private func play(_ action: @escaping (String) async -> Void) {
        guard let zone = client.selectedZone else { return }
        Task {
            await action(zone.id)
            // A stored-key play is dispatched to the server and loads in the
            // background, so there's no immediate visible result — confirm the
            // dispatch (like the Time Machine journey does) instead of looking
            // like a no-op. A genuine failure still surfaces via the global
            // error toast (client.lastActionError).
            if client.lastActionError == nil {
                withAnimation(Motion.quick) { actionMessage = String(format: LS("discovery.playStartedOnZone"), zone.displayName) }
                Task {
                    try? await Task.sleep(for: .seconds(4))
                    withAnimation(Motion.quick) { actionMessage = nil }
                }
            }
        }
    }

    // MARK: - Summary cards

    @ViewBuilder
    func summaryCards(_ stats: DatabaseManager.LibraryStats) -> some View {
        HStack(spacing: Spacing.md) {
            StatCard(label: LS("discovery.statTracks"),   value: stats.totalTracks.formatted())
            StatCard(label: LS("bm.section.artists"), value: stats.totalArtists.formatted())
            StatCard(label: LS("bm.section.albums"),   value: stats.totalAlbums.formatted())
        }
    }

    // MARK: - Decade distribution (Swift Charts area)

    @ViewBuilder
    func decadeCard(_ stats: DatabaseManager.LibraryStats) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionHeader(LS("discovery.decadeCardTitle")) { EmptyView() }

            Chart(stats.tracksByDecade, id: \.decade) { item in
                AreaMark(
                    x: .value("Decennium", item.decade),
                    y: .value("Tracks", item.count)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(.linearGradient(
                    Gradient(colors: [Color.roonGold.opacity(0.55), Color.roonGold.opacity(0.04)]),
                    startPoint: .top, endPoint: .bottom))

                LineMark(
                    x: .value("Decennium", item.decade),
                    y: .value("Tracks", item.count)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(Color.roonGold)
                .lineStyle(StrokeStyle(lineWidth: 2))
            }
            .chartYAxis { AxisMarks(position: .leading) }
            // Compact decade ticks ("1950s" → "'50s") so labels stop truncating
            // to "195…" when several decades share the axis width.
            .chartXAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let d = value.as(String.self) {
                            Text(d.count >= 3 ? "’\(d.suffix(3))" : d)
                        }
                    }
                }
            }
            .frame(height: 160)

            // Tap a decade to play a shuffled mix from it.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.sm) {
                    ForEach(stats.tracksByDecade, id: \.decade) { item in
                        if let start = Int(item.decade.dropLast()) {
                            Button(item.decade) {
                                Haptics.tap()
                                var opts = DatabaseManager.FilterOptions()
                                opts.decades = [start]
                                Task { await client.playShuffledMix(options: opts, count: 25) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                            .disabled(!client.hasActiveOutput)
                        }
                    }
                }
            }
        }
        .cardStyle()
    }

    // MARK: - Genre breakdown (Swift Charts bars)

    @ViewBuilder
    func genreCard(_ stats: DatabaseManager.LibraryStats) -> some View {
        let genres = Array(stats.topGenres.prefix(12))
        VStack(alignment: .leading, spacing: Spacing.md) {
            sectionHeader(LS("discovery.topGenres")) { EmptyView() }

            Chart(genres, id: \.genre) { item in
                BarMark(
                    x: .value("Tracks", item.count),
                    y: .value("Genre", item.genre)
                )
                .foregroundStyle(Color.roonGold.gradient)
                .cornerRadius(Radius.sm)
            }
            .chartXAxis { AxisMarks(position: .bottom) }
            .frame(height: CGFloat(genres.count) * 26 + 20)

            // Tap a genre to play a shuffled mix from it.
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.sm) {
                    ForEach(genres, id: \.genre) { item in
                        Button(item.genre) {
                            Haptics.tap()
                            var opts = DatabaseManager.FilterOptions()
                            opts.genres = [item.genre]
                            Task { await client.playShuffledMix(options: opts, count: 25) }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                        .disabled(!client.hasActiveOutput)
                    }
                }
            }
        }
        .cardStyle()
    }

    // MARK: - States

    var loadingState: some View {
        DiscoverySkeleton()
    }

    var emptyState: some View {
        ContentUnavailableView(
            LS("discovery.emptyTitle"),
            systemImage: "music.note.list",
            description: LT("discovery.emptyDescription")
        )
    }

    // MARK: - Data loading

    private func load() async {
        stats = await client.libraryStats()
        async let weekly = client.discoverWeekly()
        async let u = client.neverPlayedAlbums()
        async let d = client.forgottenAlbums()
        async let f = client.forgottenFavorites()
        async let t = client.topTracks()
        async let aotd = client.albumOfTheDay()
        let (uv, dv, fv, tv, av) = await (u, d, f, t, aotd)
        if let w = await weekly {
            weeklyAlbums = w.albumKeysSurfaced
            weeklyTracks = w.trackKeysSurfaced
        }
        undiscovered = uv.filter { !weeklyAlbums.contains($0.album.lowercased()) }
        dormant = dv.filter { !weeklyAlbums.contains($0.album.lowercased()) }
        forgotten = fv.filter { !weeklyTracks.contains(Self.trackKey($0)) }
        topTracks = tv
        albumOfDay = av
        isLoaded = true
    }

    /// Match `DiscoverWeeklyPlaylist.trackKeysSurfaced`'s "title|artist" identity.
    private static func trackKey(_ t: TrackRecord) -> String {
        "\(t.title.lowercased())|\((t.artist ?? "").lowercased())"
    }
}

// MARK: - Loading skeleton

/// A layout-matched placeholder for the Ontdek dashboard — a hero block, three
/// stat tiles, and a cover shelf — so the loading state previews the real content
/// instead of eight generic rows that don't resemble what arrives.
private struct DiscoverySkeleton: View {
    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            HStack(spacing: Spacing.lg) {
                block(width: 120, height: 120, radius: Radius.lg)
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    block(width: 80, height: 12)
                    block(width: 180, height: 22)
                    block(width: 120, height: 14)
                    Spacer(minLength: 0)
                    block(width: 110, height: 30, radius: Radius.md)
                }
                Spacer(minLength: 0)
            }
            .frame(height: 120)

            HStack(spacing: Spacing.md) {
                ForEach(0..<3, id: \.self) { _ in
                    block(height: 64, radius: Radius.lg).frame(maxWidth: .infinity)
                }
            }

            block(width: 160, height: 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: Spacing.md) {
                    ForEach(0..<4, id: \.self) { _ in
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            block(width: 130, height: 130, radius: Radius.md)
                            block(width: 100, height: 11)
                            block(width: 70, height: 9)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .opacity(pulse ? 0.5 : 1)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
        .accessibilityHidden(true)
    }

    private func block(width: CGFloat? = nil, height: CGFloat, radius: CGFloat = Radius.sm) -> some View {
        RoundedRectangle(cornerRadius: radius)
            .fill(.quaternary)
            .frame(width: width, height: height)
    }
}
