import RoonSageCore
import SwiftUI

/// Sonisch zoeken: free-text → audio search (Track E5). The query is embedded by
/// the analyzer's CLAP text encoder (/text-embed) and cosine-ranked against the
/// library's sonic embeddings — so "dreamy late-night piano" finds tracks that
/// *sound* like that, regardless of tags.
///
/// Built on `List`/`Section` (not a custom `ScrollView`/`VStack`) — see
/// `GenerateView` for why.
@MainActor
public struct SonicSearchView: View {
    public init() {}

    /// Opened with words already typed elsewhere — the library's search box
    /// hands its query over, so a literal-match miss doesn't mean retyping it
    /// into a second search screen (readiness P7: "too many doors").
    public init(initialQuery: String) {
        _query = State(initialValue: initialQuery)
        _autoRun = State(initialValue: !initialQuery.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    @Environment(RoonClient.self) private var client

    @State private var query = ""
    /// Run once on appear when handed a query, then never again — from that
    /// point the search box is the user's.
    @State private var autoRun = false
    @State private var results: [SonicEngine.Scored] = []
    @State private var lyricsHits: [DatabaseManager.LyricsSearchHit] = []   // gap C
    @State private var loading = false
    @State private var searched = false

    private let examples = [LS("sonicSearch.example1"), LS("sonicSearch.example2"),
                            LS("sonicSearch.example3"), LS("sonicSearch.example4")]

    public var body: some View {
        List {
            Section {
                LT("sonicSearch.introDescription")
                    .font(.callout).foregroundStyle(.secondary)
                searchBar
                    .listRowInsets(EdgeInsets())
                    .padding(.vertical, Spacing.xs)
                    .listRowBackground(Color.clear)
            }

            ZoneHintBanner().plainCardRow()

            if !searched && results.isEmpty {
                Section { exampleChips }
            } else if loading {
                Section { ProgressView().frame(maxWidth: .infinity) }
            } else if results.isEmpty && lyricsHits.isEmpty {
                Section {
                    ContentUnavailableView(
                        LS("sonicSearch.emptyTitle"),
                        systemImage: "sparkle.magnifyingglass",
                        description: LT("sonicSearch.emptyDescription"))
                    .listRowBackground(Color.clear)
                }
                .listRowSeparator(.hidden)
            } else {
                if !results.isEmpty { resultsSection }
                if !lyricsHits.isEmpty { lyricsSection }
            }
        }
        .screenTitle(LS("nav.sonicSearch"))
        .onAppear {
            guard autoRun else { return }
            autoRun = false
            runSearch()
        }
    }

    private var searchBar: some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "sparkle.magnifyingglass").foregroundStyle(.secondary)
            TextField(LS("sonicSearch.searchPlaceholder"), text: $query)
                .textFieldStyle(.plain)
                .onSubmit { runSearch() }
            if !query.isEmpty {
                Button { query = ""; results = []; lyricsHits = []; searched = false } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.borderless)
            }
            Button { runSearch() } label: { Text(loading ? LS("sonicSearch.searching") : LS("sonicSearch.search")) }
                .buttonStyle(.borderedProminent).tint(Color.roonGold)
                .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || loading)
        }
        .padding(Spacing.sm)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.md))
    }

    private var exampleChips: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            LT("sonicSearch.examplesHeader").font(.caption).foregroundStyle(.secondary)
            FlowChips(examples) { ex in
                query = ex; runSearch()
            }
        }
    }

    private var topRecords: [TrackRecord] {
        results.prefix(20).map {
            TrackRecord(id: $0.track.id, title: $0.track.title,
                        artist: $0.track.artist, album: $0.track.album,
                        imageKey: $0.track.imageKey)
        }
    }

    private var resultsSection: some View {
        Section("Resultaten (\(results.count))") {
            HStack(spacing: Spacing.sm) {
                Button {
                    Haptics.success()
                    Task { await client.playToActiveOutput(topRecords) }
                } label: { Label("Speel top 20", systemImage: "play.fill").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).tint(Color.roonGold)
                .disabled(!client.hasActiveOutput)
            }
            ForEach(results.prefix(40)) { scored in
                HStack(spacing: Spacing.md) {
                    AlbumArtView(imageKey: scored.track.imageKey, size: 44)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.sm))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(scored.track.title).font(.callout).lineLimit(1)
                        if let a = scored.track.artist {
                            Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        HStack(spacing: Spacing.xs) {
                            if let bpm = scored.track.bpm, bpm > 0 { Badge("\(Int(bpm)) BPM") }
                            if !scored.track.camelot.isEmpty { Badge(scored.track.camelot, tint: .roonGold) }
                        }
                    }
                    Spacer()
                    Button {
                        Task { await client.playTrack(id: scored.track.id, title: scored.track.title,
                                                      artist: scored.track.artist) }
                    } label: { Image(systemName: "play.fill") }
                    .buttonStyle(.borderless)
                    .disabled(!client.hasActiveOutput)
                }
                .padding(.vertical, Spacing.xs)
            }
        }
    }

    /// Gap C: tracks waarvan de sóngtekst de zoekterm bevat — naast het
    /// sonische resultaat, want "over welk onderwerp gaat het" en "hoe klinkt
    /// het" zijn verschillende vragen op hetzelfde zoekveld.
    private var lyricsSection: some View {
        Section("In songteksten (\(lyricsHits.count))") {
            ForEach(lyricsHits.prefix(20)) { hit in
                VStack(alignment: .leading, spacing: 2) {
                    Text(hit.track.title).font(.callout).lineLimit(1)
                    if let a = hit.track.artist {
                        Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if !hit.snippet.isEmpty {
                        Text("“\(hit.snippet)”")
                            .font(.caption).italic().foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                .padding(.vertical, Spacing.xs)
            }
        }
    }

    private func runSearch() {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty, !loading else { return }
        Haptics.tap()
        loading = true
        searched = true
        Task {
            async let sonic = client.sonicTextSearch(q, limit: 40)
            async let lyric = client.searchLyrics(q, limit: 20)
            let (r, l) = await (sonic, lyric)
            await MainActor.run { results = r; lyricsHits = l; loading = false }
        }
    }
}

/// Minimal wrapping chip row for example queries.
private struct FlowChips: View {
    let items: [String]
    let onTap: (String) -> Void
    init(_ items: [String], onTap: @escaping (String) -> Void) { self.items = items; self.onTap = onTap }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            ForEach(items, id: \.self) { item in
                Button { onTap(item) } label: {
                    Text(item).font(.callout)
                        .padding(.horizontal, Spacing.sm).padding(.vertical, 6)
                        .background(.background.secondary, in: Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }
}
