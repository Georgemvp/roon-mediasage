import SwiftUI
import RoonSageCore

/// Album-level recommendations: describe a vibe, the LLM picks albums from your
/// library to explore (library-first). Each recommendation is playable, and the
/// history is kept so you can revisit earlier sets.
///
/// Built on `List`/`Section` (not a custom `ScrollView`/`VStack`) — see
/// `GenerateView` for why.
@MainActor
public struct RecommendView: View {
    public init() {}
    @Environment(RoonClient.self) private var client

    @State private var prompt        = ""
    @State private var count         = 8
    @State private var isWorking     = false
    @State private var phase: RoonClient.GenerationPhase = .analyzing
    @State private var albums: [DatabaseManager.AlbumResult] = []
    @State private var resultFilters: RoonClient.RequestFilters? = nil
    @State private var errorMessage: String? = nil

    @State private var history: [DatabaseManager.RecommendationSummary] = []
    @State private var expandedHistoryID: Int64? = nil
    @State private var historyAlbums: [DatabaseManager.AlbumResult] = []
    @State private var pendingDelete: DatabaseManager.RecommendationSummary? = nil

    private let ideas = [
        LS("recommend.ideaRainySunday"),
        LS("recommend.ideaDeepImmersive"),
        LS("recommend.ideaJazzyLateNight"),
        LS("recommend.ideaEnergeticMorning"),
    ]

    public var body: some View {
        List {
            if client.genreCount == 0 {
                Section {
                    Label(LS("recommend.genresNotSynced"),
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(Color.roonWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            promptSection
            optionsSection
            recommendSection

            if !albums.isEmpty {
                Section(LS("Aanbevolen albums (\(albums.count))")) {
                    if let resultFilters {
                        FilterChips(filters: resultFilters).padding(.vertical, 2)
                    }
                    albumList(albums)
                }
            } else if !isWorking && history.isEmpty {
                idleSection
            }

            historySection
        }
        .animation(Motion.standard, value: albums.map(\.albumKey))
        .navigationTitle(LS("nav.recommend"))
        .confirmationDialog(
            LS("recommend.deleteConfirmTitle"),
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            presenting: pendingDelete
        ) { entry in
            Button(LS("recommend.delete"), role: .destructive) {
                client.deleteRecommendation(id: entry.id)
                history.removeAll { $0.id == entry.id }
                if expandedHistoryID == entry.id { expandedHistoryID = nil; historyAlbums = [] }
                Haptics.success()
                pendingDelete = nil
            }
            Button(LS("recommend.cancel"), role: .cancel) { pendingDelete = nil }
        } message: { entry in
            Text(entry.prompt)
        }
        .onAppear { Task { history = await client.recommendations() } }
    }

    // MARK: Form

    private var promptSection: some View {
        Section(LS("recommend.promptSectionTitle")) {
            AIPromptField(text: $prompt,
                          placeholder: LS("recommend.promptPlaceholder"),
                          minHeight: 70)
                .listRowInsets(EdgeInsets())
                .padding(.vertical, Spacing.xs)
                .listRowBackground(Color.clear)
            SuggestionChips(ideas) { prompt = $0 }
                .listRowInsets(EdgeInsets(top: Spacing.xs, leading: Spacing.lg, bottom: Spacing.xs, trailing: 0))
        }
    }

    private var optionsSection: some View {
        Section {
            HStack {
                LT("recommend.albumCount")
                Spacer()
                Picker(LS("bm.section.albums"), selection: $count) {
                    ForEach([5, 8, 12], id: \.self) { Text("\($0)").tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 180)
            }
            HStack {
                LT("recommend.playOn")
                Spacer()
                ZonePicker()
            }
        }
    }

    private var recommendSection: some View {
        Section {
            Button { Task { await recommend() } } label: {
                Label(isWorking ? LS("recommend.thinking") : LS("recommend.recommendAlbums"), systemImage: "sparkles")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
            .listRowBackground(Color.clear)

            if let err = errorMessage {
                Label(err, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.roonDanger).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if isWorking {
                // Shared stepper so Generate / Ask / Recommend feel like one family.
                GenerationStepper(current: phase, phases: [.analyzing, .candidates, .curating])
                    .padding(.vertical, Spacing.xs)
            }
        }
    }

    private var idleSection: some View {
        Section {
            ContentUnavailableView {
                Label(LS("recommend.discoverAlbums"), systemImage: "sparkles.rectangle.stack")
            } description: {
                LT("recommend.idleDescription")
            }
            .listRowBackground(Color.clear)
        }
        .listRowSeparator(.hidden)
    }

    // MARK: History

    @ViewBuilder
    private var historySection: some View {
        if !history.isEmpty {
            Section(LS("recommend.historyTitle")) {
                ForEach(history, id: \.id) { entry in
                    historyRow(entry)
                    if expandedHistoryID == entry.id {
                        albumList(historyAlbums)
                    }
                }
            }
        }
    }

    private func historyRow(_ entry: DatabaseManager.RecommendationSummary) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.prompt).font(.body).lineLimit(1)
                Text("\(entry.albumCount) albums · \(formatDate(entry.createdAt))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await toggleHistory(entry) } } label: {
                Image(systemName: expandedHistoryID == entry.id ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(expandedHistoryID == entry.id ? LS("recommend.collapse") : LS("recommend.expand"))
            Button(role: .destructive) { pendingDelete = entry } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .accessibilityLabel(LS("recommend.deleteRecommendation"))
            .help(LS("recommend.deleteRecommendationHelp"))
        }
        .contentShape(Rectangle())
        .onTapGesture { Task { await toggleHistory(entry) } }
    }

    @ViewBuilder
    private func albumList(_ items: [DatabaseManager.AlbumResult]) -> some View {
        ForEach(items, id: \.albumKey) { album in
            AIResultRow(title: album.album,
                        subtitle: "\(album.artist ?? LS("recommend.unknownArtist"))\(album.year.map { " · \($0)" } ?? "")",
                        imageKey: album.imageKey) {
                HStack(spacing: Spacing.xs) {
                    Button {
                        guard let zone = client.selectedZone?.id else { return }
                        Haptics.tap()
                        Task { await client.playAlbum(albumKey: album.albumKey, zoneID: zone) }
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .disabled(client.selectedZone == nil)
                    .accessibilityLabel(LS("Speel \(album.album) af"))
                    .help(client.selectedZone == nil ? LS("recommend.pickZoneFirst") : LS("recommend.playAlbumHelp"))

                    Button {
                        Haptics.tap()
                        Task { await client.playAlbumLocally(albumKey: album.albumKey) }
                    } label: {
                        Image(systemName: "iphone")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(LS("Speel \(album.album) op dit apparaat"))
                    .help(LS("recommend.playLocalHelp"))
                }
            }
        }
    }

    private func toggleHistory(_ entry: DatabaseManager.RecommendationSummary) async {
        if expandedHistoryID == entry.id {
            expandedHistoryID = nil
            historyAlbums = []
        } else {
            expandedHistoryID = entry.id
            historyAlbums = await client.recommendationAlbums(id: entry.id)
        }
    }

    private func formatDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso) {
            let rel = RelativeDateTimeFormatter()
            rel.locale = Locale(identifier: "nl_NL")
            return rel.localizedString(for: d, relativeTo: Date())
        }
        return iso
    }

    private func recommend() async {
        isWorking = true; errorMessage = nil; albums = []; resultFilters = nil
        phase = .analyzing
        defer { isWorking = false }

        let request = prompt.trimmingCharacters(in: .whitespaces)

        let filters = await client.analyzeForFilters(request: request)

        phase = .candidates
        let candidates = await client.candidateAlbums(filters: filters, limit: 60)
        guard !candidates.isEmpty else {
            errorMessage = LS("recommend.noAlbumsError")
            return
        }

        phase = .curating
        let list = candidates.enumerated().map { i, a -> String in
            var line = "\(i + 1). \(a.album) — \(a.artist ?? "Onbekend")\(a.year.map { " (\($0))" } ?? "")"
            if !a.genres.isEmpty { line += " [\(a.genres.prefix(3).joined(separator: ", "))]" }
            return line
        }.joined(separator: "\n")
        let system = """
        You recommend albums for a personal music library. From the numbered album list, \
        choose exactly \(count) albums that best match the request. Favor a variety of artists. \
        Lean toward artists the listener has thumbed up and avoid those they have thumbed down \
        (unless the request explicitly asks for them). \
        Return ONLY the album numbers separated by commas — no explanation. Example: 3, 11, 2, 8
        """
        let taste = await client.feedbackPromptBlock()
        let user = "Request: \(request)\(taste)\n\nAvailable albums:\n\(list)"

        do {
            let resp = try await LLMClient.shared.complete(
                system: system, user: user, config: client.effectiveLLMConfig(),
                temperature: 0.3, maxTokens: 256)
            let numbers = PlaylistAssembler.picks(from: resp, max: candidates.count)
            guard !numbers.isEmpty else {
                errorMessage = LS("recommend.processError")
                return
            }
            albums = numbers.compactMap { n in (n >= 1 && n <= candidates.count) ? candidates[n - 1] : nil }
            resultFilters = filters
            Haptics.success()

            client.saveRecommendation(prompt: request, albums: albums)
            history = await client.recommendations()
        } catch {
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }
}
