import SwiftUI
import Observation
import RoonSageCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// MARK: - View model

/// Owns all of GenerateView's UI + orchestration state so the view itself is pure
/// presentation. The heavy pipeline lives in `RoonClient.generatePlaylist`; this
/// model wires it to the screen: staged progress, a cancellable/token-guarded
/// run, an editable result, and saving.
@MainActor
@Observable
final class GenerateModel {
    var prompt        = ""
    var targetCount   = 20
    /// Size the set by play-time instead of track count (U3).
    var useDuration   = false
    var targetMinutes = 60
    /// The radio dial, reused for generation: 0 = vertrouwd, 1 = ontdekkend.
    var adventurousness = RoonClient.defaultAdventurousness
    /// Energy shape the final set is flow-ordered into; nil = auto (derived from
    /// the request).
    var arc: RadioSequencer.Arc? = nil
    /// Optional seed anchors (U2): shape the sound like a station's seeds.
    var seedArtists: [String] = []
    var seedTrackKeys: [String] = []
    /// Library artists/tracks to pick seeds from — loaded lazily.
    var facetOptions: RoonClient.RadioFacetOptions? = nil
    var isGenerating  = false
    var phase: RoonClient.GenerationPhase? = nil
    var result: RoonClient.GenerationResult? = nil
    /// Editable working copy of the curated tracks (mutated by the row actions).
    var tracks: [TrackRecord] = []
    var playlistName  = ""
    var justSaved     = false
    var qobuzStatus: String? = nil
    var errorMessage: String? = nil

    @ObservationIgnored private var genTask: Task<Void, Never>? = nil
    /// Monotonic token so a cancelled/superseded run can't reset shared state or
    /// publish a result under a newer run.
    @ObservationIgnored private var genToken = 0
    @ObservationIgnored private var savedTask: Task<Void, Never>? = nil

    var canGenerate: Bool { !prompt.trimmingCharacters(in: .whitespaces).isEmpty }
    var canSave: Bool { !playlistName.trimmingCharacters(in: .whitespaces).isEmpty && !tracks.isEmpty }

    func apply(_ t: PlaylistTemplate) {
        prompt = t.prompt
        targetCount = [10, 20, 30, 50].min(by: { abs($0 - t.trackCount) < abs($1 - t.trackCount) }) ?? 20
        playlistName = t.name
        Haptics.tap()
    }

    func startGenerate(client: RoonClient) {
        genTask?.cancel()
        genToken &+= 1
        let token = genToken
        genTask = Task { await generate(token: token, client: client) }
    }

    func stop() { genTask?.cancel() }

    /// Load the seed pickers' options once (artists + tracks from the library).
    func loadFacetOptions(client: RoonClient) async {
        guard facetOptions == nil else { return }
        facetOptions = await client.radioFacetOptions()
    }

    private func generate(token: Int, client: RoonClient) async {
        let request = prompt.trimmingCharacters(in: .whitespaces)
        guard !request.isEmpty else { return }
        isGenerating = true
        errorMessage = nil
        justSaved = false
        qobuzStatus = nil
        phase = .analyzing
        // Keep any existing result visible during a regenerate; restore nothing on
        // Stop. The token guard stops a superseded run from clobbering newer state.
        defer { if token == genToken { isGenerating = false; phase = nil } }

        do {
            let r = try await client.generatePlaylist(request: request, target: targetCount,
                                                      adventurousness: adventurousness,
                                                      arc: arc,
                                                      targetMinutes: useDuration ? targetMinutes : nil,
                                                      seedArtists: seedArtists,
                                                      seedTrackKeys: seedTrackKeys) { [weak self] p in
                guard let self, token == self.genToken else { return }
                withAnimation(Motion.quick) { self.phase = p }
            }
            guard !Task.isCancelled, token == genToken else { return }
            result = r
            playlistName = r.title
            withAnimation(Motion.spring) { tracks = r.tracks }
            Haptics.success()
        } catch {
            if Task.isCancelled || token != genToken { return }
            errorMessage = error.localizedDescription
            Haptics.error()
        }
    }

    func save(client: RoonClient) {
        let name = playlistName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !tracks.isEmpty else { return }
        client.savePlaylist(name: name, tracks: tracks)
        Haptics.success()
        justSaved = true
        savedTask?.cancel()
        savedTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.justSaved = false
        }
    }

    func saveToQobuz(client: RoonClient) {
        let name = playlistName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !tracks.isEmpty else { return }
        qobuzStatus = LS("generate.qobuzSaving")
        let snapshot = tracks
        Task { [weak self] in
            if let r = await client.saveToQobuz(name: name, tracks: snapshot) {
                self?.qobuzStatus = "Bewaard in Qobuz — \(r.matched)/\(r.total) tracks gematcht."
            } else {
                self?.qobuzStatus = LS("generate.qobuzFailed")
            }
        }
    }

    func playAll(client: RoonClient) {
        guard let z = client.selectedZone?.id, !tracks.isEmpty else { return }
        Haptics.tap()
        let snapshot = tracks
        Task { await client.curateTracks(snapshot, zoneID: z) }
    }

    func playOne(_ track: TrackRecord, client: RoonClient) {
        guard let z = client.selectedZone?.id else { return }
        Haptics.tap()
        Task { await client.curateTracks([track], zoneID: z) }
    }

    func queueOne(_ track: TrackRecord, next: Bool, client: RoonClient) {
        guard let z = client.selectedZone?.id else { return }
        Haptics.tap()
        Task { await client.queueTracks([track], next: next, zoneID: z) }
    }

    func remove(_ track: TrackRecord) {
        withAnimation(Motion.quick) { tracks.removeAll { $0.id == track.id } }
        Haptics.tap()
    }

    func move(_ track: TrackRecord, by delta: Int) {
        guard let i = tracks.firstIndex(where: { $0.id == track.id }) else { return }
        let j = i + delta
        guard tracks.indices.contains(j) else { return }
        withAnimation(Motion.quick) { tracks.swapAt(i, j) }
        Haptics.tap()
    }
}

// MARK: - View

/// AI playlist generation. The whole analyse → candidates → curate → name
/// pipeline lives in `RoonClient.generatePlaylist` (Core); this view is pure
/// presentation over `GenerateModel`, with an *editable* result the user can
/// refine (play/queue/reorder/remove a track) before saving.
///
/// Built on `List`/`Section` (not a custom `ScrollView`/`VStack`) — every other
/// sectioned screen in the app (Settings, Playlists, Queue) uses the same
/// container, and List clamps its own width correctly, which sidesteps an iOS 26
/// NavigationStack layout bug that custom ScrollView content was vulnerable to.
@MainActor
public struct GenerateView: View {
    /// Optional seed carried in from Ask ("Verfijn tot playlist →") so the same
    /// idea doesn't have to be retyped; only used when the prompt is still empty.
    private let initialPrompt: String?
    public init(initialPrompt: String? = nil) { self.initialPrompt = initialPrompt }
    @Environment(RoonClient.self) private var client
    @State private var model = GenerateModel()
    @State private var showTemplates = false

    /// One featured template per category for quick access; all 63 live behind
    /// "Alle sjablonen".
    private var featured: [PlaylistTemplate] {
        PlaylistTemplates.categories.compactMap { PlaylistTemplates.inCategory($0).first }
    }

    public var body: some View {
        @Bindable var model = model
        return List {
            promptSection
            templatesSection
            seedsSection
            optionsSection
            generateSection

            if model.isGenerating, model.result == nil {
                Section { SkeletonRows(count: min(model.targetCount, 8)) }
                    .listRowSeparator(.hidden)
                    .transition(.opacity)
            } else if let result = model.result {
                resultSection(result, name: $model.playlistName)
            } else {
                idleSection
            }
        }
        .animation(Motion.standard, value: model.result?.title)
        .animation(Motion.quick, value: model.errorMessage)
        .navigationTitle(LS("generate.navTitle"))
        .task {
            if model.prompt.isEmpty, let seed = initialPrompt, !seed.isEmpty { model.prompt = seed }
            await client.ensureFeedbackLoaded()
            await model.loadFacetOptions(client: client)
        }
        #if os(iOS)
        .scrollDismissesKeyboard(.interactively)
        #endif
        .sheet(isPresented: $showTemplates) {
            TemplatePicker { t in model.apply(t); showTemplates = false }
        }
    }

    // MARK: Form

    private var promptSection: some View {
        Section(LS("generate.promptSection")) {
            AIPromptField(text: $model.prompt,
                          placeholder: LS("generate.promptPlaceholder"))
                .listRowInsets(EdgeInsets())
                .padding(.vertical, Spacing.xs)
                .listRowBackground(Color.clear)
        }
    }

    private var templatesSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Spacing.sm) {
                    ForEach(featured) { t in
                        Button { model.apply(t) } label: {
                            HStack(spacing: Spacing.xs) {
                                Image(systemName: t.categorySymbol)
                                    .foregroundStyle(Color.roonGold)
                                Text(t.name).font(.callout).lineLimit(1)
                            }
                            .padding(.horizontal, Spacing.md)
                            .padding(.vertical, Spacing.sm)
                        }
                        .buttonStyle(.bordered)
                        .buttonBorderShape(.capsule)
                    }
                }
                .padding(.horizontal, 1)
            }
            .listRowInsets(EdgeInsets(top: Spacing.xs, leading: Spacing.lg, bottom: Spacing.xs, trailing: 0))
        } header: {
            HStack {
                LT("generate.quickTemplates")
                Spacer()
                Button { showTemplates = true } label: {
                    Label(LS("generate.allTemplates"), systemImage: "square.grid.2x2").font(.caption)
                }
                .buttonStyle(.borderless)
                .textCase(nil)
            }
        }
    }

    /// Optional seed anchors (U2) — shape the sound around chosen artists/tracks,
    /// exactly like a custom radio's seeds. Hidden until the library options load.
    @ViewBuilder
    private var seedsSection: some View {
        if let opts = model.facetOptions, !opts.artists.isEmpty || !opts.tracks.isEmpty {
            Section {
                NavigationLink {
                    FacetMultiSelectView(title: LS("bm.section.artists"),
                                         options: opts.artists.map { .init(key: $0, label: $0) },
                                         featured: opts.featuredArtists.map { .init(key: $0, label: $0) },
                                         selection: $model.seedArtists.asSet)
                } label: {
                    seedRow(LS("bm.section.artists"), systemImage: "music.mic", count: model.seedArtists.count)
                }
                NavigationLink {
                    FacetMultiSelectView(title: LS("bm.section.tracks"), options: opts.tracks,
                                         featured: opts.featuredTracks,
                                         selection: $model.seedTrackKeys.asSet)
                } label: {
                    seedRow(LS("bm.section.tracks"), systemImage: "music.note", count: model.seedTrackKeys.count)
                }
            } header: {
                LT("generate.seedsOptional")
            } footer: {
                LT("generate.seedsFooter")
            }
        }
    }

    private func seedRow(_ title: String, systemImage: String, count: Int) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(count == 0 ? LS("generate.none") : "\(count)").foregroundStyle(.secondary)
        }
    }

    private var optionsSection: some View {
        Section {
            Picker(LS("generate.size"), selection: $model.useDuration) {
                LT("generate.count").tag(false)
                LT("generate.duration").tag(true)
            }
            .pickerStyle(.segmented)
            if model.useDuration {
                HStack {
                    LT("generate.playtime")
                    Spacer()
                    Picker(LS("generate.playtime"), selection: $model.targetMinutes) {
                        Text("30 min").tag(30)
                        Text("60 min").tag(60)
                        Text("90 min").tag(90)
                        Text("120 min").tag(120)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 240)
                }
            } else {
                HStack {
                    LT("generate.trackCount")
                    Spacer()
                    Picker(LS("generate.trackCount"), selection: $model.targetCount) {
                        Text("10").tag(10)
                        Text("20").tag(20)
                        Text("30").tag(30)
                        Text("50").tag(50)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 220)
                }
            }
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack {
                    LT("generate.adventurousness")
                    Spacer()
                    Text(adventureLabel).font(.caption).foregroundStyle(Color.roonGold)
                }
                Slider(value: $model.adventurousness, in: 0...1, step: 0.05)
                    .tint(Color.roonGold)
            }
            HStack {
                LT("generate.arc")
                Spacer()
                Picker(LS("generate.arc"), selection: $model.arc) {
                    LT("generate.arcAuto").tag(RadioSequencer.Arc?.none)
                    LT("generate.arcSmooth").tag(RadioSequencer.Arc?.some(.smooth))
                    LT("generate.arcRise").tag(RadioSequencer.Arc?.some(.gentleRise))
                    LT("generate.arcPeak").tag(RadioSequencer.Arc?.some(.peak))
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
                .help(LS("generate.arcHelp"))
            }
            HStack {
                LT("generate.playOn")
                Spacer()
                ZonePicker()
            }
        }
    }

    /// Mirrors CustomRadioEditorView's dial wording so the knob reads the same
    /// everywhere.
    private var adventureLabel: String {
        switch model.adventurousness {
        case ..<0.2:  return LS("generate.advMostlyKnown")
        case ..<0.45: return LS("generate.advLightExplore")
        case ..<0.7:  return LS("generate.advExploring")
        default:      return LS("generate.advDiscovering")
        }
    }

    private var generateSection: some View {
        Section {
            Button { model.startGenerate(client: client) } label: {
                Label(generateButtonTitle, systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!model.canGenerate || model.isGenerating)
            .listRowInsets(EdgeInsets(top: Spacing.sm, leading: Spacing.lg, bottom: Spacing.sm, trailing: Spacing.lg))
            .listRowBackground(Color.clear)

            if model.isGenerating {
                Button(role: .cancel) { model.stop() } label: {
                    Label(LS("generate.stop"), systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .transition(.opacity)
            }

            if let err = model.errorMessage {
                Label(err, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.roonDanger)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }

            if model.isGenerating {
                GenerationStepper(current: model.phase ?? .analyzing)
                    .padding(.vertical, Spacing.xs)
                    .transition(.opacity)
            }
        }
    }

    private var generateButtonTitle: String {
        if model.isGenerating { return LS("generate.generating") }
        return model.result == nil ? LS("generate.generatePlaylist") : LS("generate.regenerate")
    }

    /// Mirrors the empty-state idiom used elsewhere (e.g. `PlaylistsView`) so
    /// every "nothing here yet" screen in the app reads as one family.
    private var idleSection: some View {
        Section {
            ContentUnavailableView {
                Label(LS("generate.idleTitle"), systemImage: "wand.and.stars")
            } description: {
                LT("generate.idleDescription")
            }
            .listRowBackground(Color.clear)
        }
        .listRowSeparator(.hidden)
    }

    // MARK: Result

    @ViewBuilder
    private func resultSection(_ r: RoonClient.GenerationResult, name: Binding<String>) -> some View {
        Section {
            resultHeader(r)
            FilterChips(filters: r.filters, poolSize: r.poolSize)
                .padding(.vertical, 2)
        } header: {
            LT("generate.result")
        }

        Section(LS("generate.sectionSave")) {
            saveRow(name)
            if let qobuzStatus = model.qobuzStatus {
                Text(qobuzStatus).font(.caption).foregroundStyle(.secondary)
            }
        }

        Section(LS("section.playback")) {
            playRow
        }

        if let trace = r.trace, !trace.isEmpty {
            Section {
                DisclosureGroup(LS("generate.diagnostics")) {
                    Text(trace)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 2)
                    Button {
                        #if os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(trace, forType: .string)
                        #else
                        UIPasteboard.general.string = trace
                        #endif
                        Haptics.tap()
                    } label: {
                        Label(LS("generate.copyDiagnostics"), systemImage: "doc.on.doc").font(.caption)
                    }
                }
            } footer: {
                LT("generate.diagnosticsFooter")
            }
        }

        Section("Tracks (\(model.tracks.count))") {
            ForEach(Array(model.tracks.enumerated()), id: \.element.id) { i, t in
                AIResultRow(index: i + 1, title: t.title, subtitle: subtitle(t), imageKey: t.imageKey) {
                    HStack(spacing: Spacing.sm) {
                        TrackFeedbackButtons(title: t.title, artist: t.artist, album: t.album)
                        Button { model.playOne(t, client: client) } label: { Image(systemName: "play.fill") }
                            .buttonStyle(.borderless)
                            .disabled(!client.hasActiveOutput)
                            .accessibilityLabel(LS("Speel \(t.title)"))
                    }
                }
                .contextMenu {
                    Button { model.playOne(t, client: client) } label: { Label(LS("bm.playNow"), systemImage: "play.fill") }
                        .disabled(!client.hasActiveOutput)
                    Button { model.queueOne(t, next: true, client: client) } label: {
                        Label(LS("generate.playNext"), systemImage: "text.line.first.and.arrowtriangle.forward")
                    }
                    .disabled(!client.hasActiveOutput)
                    Divider()
                    Button { model.move(t, by: -1) } label: { Label(LS("generate.moveUp"), systemImage: "arrow.up") }
                        .disabled(i == 0)
                    Button { model.move(t, by: 1) } label: { Label(LS("generate.moveDown"), systemImage: "arrow.down") }
                        .disabled(i == model.tracks.count - 1)
                    Divider()
                    Button(role: .destructive) { model.remove(t) } label: {
                        Label(LS("generate.removeFromPlaylist"), systemImage: "trash")
                    }
                }
            }
            .onMove { from, to in model.tracks.move(fromOffsets: from, toOffset: to); Haptics.tap() }
            .onDelete { idx in model.tracks.remove(atOffsets: idx); Haptics.tap() }
        }
    }

    private func resultHeader(_ r: RoonClient.GenerationResult) -> some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Image(systemName: "wand.and.stars")
                .foregroundStyle(Color.roonGold)
                .symbolEffect(.bounce, value: model.tracks.count)
            VStack(alignment: .leading, spacing: 4) {
                Text(model.playlistName.isEmpty ? r.title : model.playlistName)
                    .font(.title3.bold())
                if let desc = r.description, !desc.isEmpty {
                    Text(desc)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 5) {
                    Text("\(model.tracks.count) tracks")
                    if model.justSaved { LT("generate.savedInline").foregroundStyle(Color.roonGold) }
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                if !r.aiCurated {
                    Label(LS("generate.autoAssembled"),
                          systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(Color.roonWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = r.droppedNote {
                    Label(note, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.roonWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let note = r.fallbackNote {
                    Label(note, systemImage: "waveform.slash")
                        .font(.caption)
                        .foregroundStyle(Color.roonWarning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }

    private func saveRow(_ name: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            TextField(LS("generate.namePlaceholder"), text: name)
                .textFieldStyle(.roundedBorder)
            HStack(spacing: Spacing.sm) {
                Button { model.save(client: client) } label: {
                    Label(model.justSaved ? LS("generate.saved") : LS("generate.save"),
                          systemImage: model.justSaved ? "checkmark" : "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!model.canSave)

                if client.qobuzConfigured {
                    Button { model.saveToQobuz(client: client) } label: {
                        Label("Qobuz", systemImage: "cloud")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!model.canSave)
                    .help(LS("generate.qobuzHelp"))
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Two evenly-split, full-width actions — never overflows regardless of how
    /// long the zone name or device label is (unlike a free-sizing HStack).
    private var playRow: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                // Follows the active output: the selected zone, or this device when
                // "dit apparaat" is the chosen output.
                Button {
                    if client.localOutputSelected {
                        Task { await client.playLocally(model.tracks) }
                    } else {
                        model.playAll(client: client)
                    }
                } label: {
                    Label(LS("generate.playAll"), systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!client.hasActiveOutput || model.tracks.isEmpty)
            }
            if !client.hasActiveOutput {
                LT("generate.noZone")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func subtitle(_ t: TrackRecord) -> String {
        var s = t.artist ?? ""
        if let y = t.year { s += s.isEmpty ? "\(y)" : " · \(y)" }
        // "Waarom deze track" — the engine's reason per pick (U4).
        if let reason = model.result?.reasonByTrackID[t.id], !reason.isEmpty {
            s += s.isEmpty ? reason : " · \(reason)"
        }
        return s
    }
}

// MARK: - Template picker sheet

/// Browse all 63 built-in templates by category. Picking one fills the prompt.
@MainActor
private struct TemplatePicker: View {
    let onPick: (PlaylistTemplate) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var category = PlaylistTemplates.categories.first ?? "Sfeer"

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: Spacing.md)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.sm) {
                        ForEach(PlaylistTemplates.categories, id: \.self) { cat in
                            let isOn = cat == category
                            Button {
                                withAnimation(Motion.quick) { category = cat }
                            } label: {
                                Text(cat)
                                    .font(.callout.weight(isOn ? .semibold : .regular))
                                    .padding(.horizontal, Spacing.md)
                                    .padding(.vertical, Spacing.sm)
                                    .background(isOn ? AnyShapeStyle(Color.roonGold) : AnyShapeStyle(.quaternary),
                                                in: Capsule())
                                    .foregroundStyle(isOn ? Color.black : Color.primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.sm)
                }

                ScrollView {
                    LazyVGrid(columns: columns, spacing: Spacing.md) {
                        ForEach(PlaylistTemplates.inCategory(category)) { t in
                            Button { onPick(t) } label: { card(t) }
                                .buttonStyle(.plain)
                        }
                    }
                    .padding(Spacing.lg)
                }
            }
            .navigationTitle(LS("generate.templatesTitle"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                Button(LS("generate.close")) { dismiss() }
            }
        }
    }

    private func card(_ t: PlaylistTemplate) -> some View {
        VStack(spacing: Spacing.xs) {
            Text(t.icon).font(.system(size: 34))
            Text(t.name)
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text("\(t.trackCount) tracks")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 110)
        .padding(Spacing.md)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.lg)
                .strokeBorder(Color.roonGold.opacity(0.15))
        )
        .accessibilityLabel("\(t.name), \(t.trackCount) tracks")
    }
}
