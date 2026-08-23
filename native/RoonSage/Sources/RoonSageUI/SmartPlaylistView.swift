import AudioAnalysis
import RoonSageCore
import SwiftUI

/// Playlists made of rules instead of prompts.
///
/// The other three tools in this hub ask an LLM to curate. This one asks the
/// database. That makes it the only one that is exactly reproducible, costs
/// nothing to run, and works with no model loaded — and it is the right tool
/// whenever the wanted set is describable ("house between 118 and 124 BPM in 8A
/// that I haven't played since spring") rather than evocative.
///
/// The rules ARE `SmartPlaylistRules`, the same value the engine compiles and
/// the same JSON that can be stored — the controls here only edit it. Every
/// change re-runs the preview, so the count under the header is the honest
/// answer to "does this rule find anything", which is the question a rule
/// builder exists to answer.
@MainActor
struct SmartPlaylistView: View {
    @Environment(RoonClient.self) private var client

    @State private var rules = SmartPlaylistRules()
    @State private var genres: Set<String> = []
    @State private var camelot: Set<String> = []
    @State private var useBPM = false
    @State private var bpmLow = 110.0
    @State private var bpmHigh = 130.0
    @State private var useEnergy = false
    @State private var energyLow = 0.3
    @State private var energyHigh = 0.9
    @State private var notPlayedDays = 0
    @State private var minPlays = 0
    @State private var excludeLive = true
    @State private var limit = 40
    @State private var soundsLikeNowPlaying = false

    @State private var facets: RoonClient.RadioFacetOptions?
    @State private var preview: [DatabaseManager.LibraryTrackRow] = []
    @State private var isEvaluating = false
    @State private var previewTask: Task<Void, Never>?
    @State private var showSaveSheet = false
    @State private var playlistName = ""
    @State private var savedMessage: String?

    /// The 24 Camelot codes, in wheel order — 1A…12A then 1B…12B. Generated
    /// rather than listed: the wheel is a rule, and a typo in a hand-written
    /// list would produce a key that matches nothing with no error.
    private static let camelotCodes: [String] =
        (1...12).map { "\($0)A" } + (1...12).map { "\($0)B" }

    /// The now-playing track's match key, when there is one — the only seed this
    /// screen offers for "klinkt als". Picking an arbitrary track would need a
    /// whole library browser inside a rule editor; the thing you are listening
    /// to is the seed you actually want, and it is one tap away.
    ///
    /// `activeNowPlaying` rather than the on-device player, so this works while
    /// listening on a Roon zone too — and the key is derived with
    /// `TrackIdentity.matchKey`, the same function that produced the keys the
    /// embeddings are stored under.
    private var nowPlayingSeed: (key: String, title: String)? {
        guard let np = client.activeNowPlaying else { return nil }
        let key = TrackIdentity.matchKey(artist: np.artist, album: np.album, title: np.title)
        return key.isEmpty ? nil : (key, np.title)
    }

    var body: some View {
        Form {
            summarySection
            genreSection
            sonicSection
            historySection
            outputSection
            previewSection
        }
        .formStyle(.grouped)
        .task { facets = await client.radioFacetOptions() }
        .task(id: rulesSignature) { await evaluate() }
        .alert(LS("smart.saveTitle"), isPresented: $showSaveSheet) {
            TextField(LS("smart.playlistName"), text: $playlistName)
            Button(LS("smart.cancel"), role: .cancel) {}
            Button(LS("smart.save")) { Task { await save() } }
        } message: {
            Text(String(format: LS("smart.saveMessage"), preview.count))
        }
    }

    // MARK: Sections

    private var summarySection: some View {
        Section {
            HStack {
                if isEvaluating {
                    ProgressView().controlSize(.small)
                } else {
                    Text("\(preview.count)")
                        .font(.title2.bold().monospacedDigit())
                }
                Text(LS("smart.matchingTracks"))
                    .font(.subheadline).foregroundStyle(.secondary)
                Spacer()
            }
            if let savedMessage {
                Text(savedMessage).font(.caption).foregroundStyle(Color.roonGold)
            }
        } footer: {
            Text(LS("smart.explainer"))
        }
    }

    private var genreSection: some View {
        Section(LS("smart.genres")) {
            if let facets, !facets.genres.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: Spacing.sm) {
                        ForEach(facets.genres.prefix(24), id: \.key) { option in
                            chip(option.label.capitalized, on: genres.contains(option.key)) {
                                toggle(option.key, in: &genres)
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }
            } else {
                Text(LS("smart.noGenresYet")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var sonicSection: some View {
        Section(LS("smart.sound")) {
            Toggle(LS("smart.useBPM"), isOn: $useBPM)
            if useBPM {
                stepperRow(LS("smart.bpmFrom"), value: $bpmLow, range: 40...220, step: 2)
                stepperRow(LS("smart.bpmTo"), value: $bpmHigh, range: 40...220, step: 2)
            }
            Toggle(LS("smart.useEnergy"), isOn: $useEnergy)
            if useEnergy {
                VStack(alignment: .leading) {
                    Text(String(format: LS("smart.energyRange"), energyLow, energyHigh))
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    HStack {
                        Slider(value: $energyLow, in: 0...1)
                        Slider(value: $energyHigh, in: 0...1)
                    }
                }
            }
            DisclosureGroup(LS("smart.camelotKeys")) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 54), spacing: Spacing.sm)],
                          spacing: Spacing.sm) {
                    ForEach(Self.camelotCodes, id: \.self) { code in
                        chip(code, on: camelot.contains(code)) { toggle(code, in: &camelot) }
                    }
                }
                .padding(.vertical, Spacing.xs)
            }
            if let seed = nowPlayingSeed {
                Toggle(String(format: LS("smart.soundsLike"), seed.title), isOn: $soundsLikeNowPlaying)
            }
        }
    }

    private var historySection: some View {
        Section(LS("smart.history")) {
            Stepper(notPlayedDays == 0
                        ? LS("smart.notPlayedOff")
                        : String(format: LS("smart.notPlayedDays"), notPlayedDays),
                    value: $notPlayedDays, in: 0...730, step: 30)
            Stepper(minPlays == 0
                        ? LS("smart.minPlaysOff")
                        : String(format: LS("smart.minPlaysValue"), minPlays),
                    value: $minPlays, in: 0...50)
            Toggle(LS("smart.excludeLive"), isOn: $excludeLive)
        }
    }

    private var outputSection: some View {
        Section(LS("smart.output")) {
            Stepper(String(format: LS("smart.trackCount"), limit), value: $limit, in: 10...200, step: 10)
            Button {
                Haptics.tap()
                Task { await client.playToActiveOutput(preview.map(\.asTrackRecord)) }
            } label: {
                Label(LS("smart.play"), systemImage: "play.fill")
            }
            .disabled(preview.isEmpty || !client.hasActiveOutput)
            Button {
                playlistName = ""
                showSaveSheet = true
            } label: {
                Label(LS("smart.saveAsPlaylist"), systemImage: "plus.rectangle.on.folder")
            }
            .disabled(preview.isEmpty)
        }
    }

    @ViewBuilder
    private var previewSection: some View {
        if !preview.isEmpty {
            Section(LS("smart.preview")) {
                ForEach(preview.prefix(30)) { row in
                    LibraryTrackRow(track: row, canPlay: client.hasActiveOutput) {
                        Task { await client.playToActiveOutput([row.asTrackRecord]) }
                    }
                }
            }
        }
    }

    // MARK: Rules

    /// The rules as the engine will see them. One place builds this, so the
    /// preview and the save can never disagree about what was asked for.
    private var currentRules: SmartPlaylistRules {
        SmartPlaylistRules(
            genre: genres.isEmpty ? nil : Array(genres),
            bpmRange: useBPM ? .init(min: Swift.min(bpmLow, bpmHigh), max: Swift.max(bpmLow, bpmHigh)) : nil,
            camelotKeys: camelot.isEmpty ? nil : Array(camelot),
            energyRange: useEnergy
                ? .init(min: Swift.min(energyLow, energyHigh), max: Swift.max(energyLow, energyHigh))
                : nil,
            lastPlayedDaysAgo: notPlayedDays > 0 ? notPlayedDays : nil,
            minPlayCount: minPlays > 0 ? minPlays : nil,
            sonicSimilarity: (soundsLikeNowPlaying ? nowPlayingSeed : nil)
                .map { .init(matchKey: $0.key) },
            excludeLive: excludeLive,
            limit: limit)
    }

    /// Re-evaluate on any rule change. The JSON encoding doubles as the change
    /// key — it is the canonical form of the rules, so two states that encode
    /// identically genuinely are the same query and must not re-run it.
    private var rulesSignature: String {
        (try? currentRules.encodedJSON()) ?? ""
    }

    private func evaluate() async {
        previewTask?.cancel()
        isEvaluating = true
        savedMessage = nil
        let snapshot = currentRules
        let task = Task { [snapshot] in
            let rows = await client.smartPlaylistTracks(snapshot)
            guard !Task.isCancelled else { return }
            preview = rows
            isEvaluating = false
        }
        previewTask = task
        await task.value
    }

    private func save() async {
        let name = playlistName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if await client.saveSmartPlaylist(name: name, rules: currentRules) != nil {
            savedMessage = String(format: LS("smart.saved"), name)
        }
    }

    // MARK: Small pieces

    private func toggle(_ value: String, in set: inout Set<String>) {
        if set.contains(value) { set.remove(value) } else { set.insert(value) }
    }

    private func chip(_ label: String, on: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.caption)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(on ? Color.roonGold.opacity(0.25) : Color.platformQuaternaryFill,
                            in: Capsule())
                .foregroundStyle(on ? Color.roonGold : .primary)
        }
        .buttonStyle(.plain)
    }

    private func stepperRow(_ label: String, value: Binding<Double>,
                            range: ClosedRange<Double>, step: Double) -> some View {
        Stepper(value: value, in: range, step: step) {
            HStack {
                Text(label)
                Spacer()
                Text("\(Int(value.wrappedValue))").monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }
}
