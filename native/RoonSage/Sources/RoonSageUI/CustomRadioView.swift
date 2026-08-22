import RoonSageCore
import SwiftUI

/// "Mijn radio's" — manage user-composed sonic radios: create, edit, enable/
/// disable, toggle Qobuz sync, play, delete. These are the server-of-record
/// `RadioConfig`s, so the same set shows on every client; the analyzer mirrors the
/// enabled ones to Qobuz.
///
/// Built on `List` + `.plainCardRow()` like `SonicRadioView` (see `GenerateView`
/// for why a custom ScrollView is avoided).
@MainActor
public struct CustomRadioView: View {
    @Environment(RoonClient.self) private var client
    @State private var configs: [RadioConfig] = []
    @State private var options: RoonClient.RadioFacetOptions?
    @State private var loaded = false
    @State private var isLoading = false
    @State private var editing: RadioConfig?
    @State private var message: String?

    // AI radios (auto-generated) — managed here too: on/off + "overnemen".
    @State private var aiMgmt: AIRadioManagement?
    @State private var aiCategory: RoonClient.RadioCategory = .artist
    @State private var aiLoading = false
    @State private var aiLoaded = false

    public init() {}

    public var body: some View {
        List {
            if let radio = client.activeRadio { activeBanner(radio).plainCardRow() }
            ZoneHintBanner().plainCardRow()
            header.plainCardRow()

            if !client.qobuzConfigured {
                warningRow(LS("customRadio.qobuzNotConfigured"))
                    .plainCardRow()
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary).plainCardRow()
            }

            LT("customRadio.selfComposed").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                .plainCardRow()

            AsyncStateView(isLoading: isLoading || !loaded, isEmpty: configs.isEmpty,
                           onRetry: { Task { await load(force: true) } }) {
                ForEach(configs) { configRow($0) }
            } empty: {
                emptyState
            }
            .plainCardRow()

            aiSection.plainCardRow()
        }
        .navigationTitle(LS("customRadio.title"))
        .toolbar {
            Button { newConfig() } label: { Image(systemName: "plus") }
                .help(LS("customRadio.newRadioHelp"))
                .disabled(options == nil)
        }
        .task { await load(force: false) }
        .task { await loadAI(force: false) }
        .onChange(of: aiCategory) { Task { await loadAI(force: true) } }
        .sheet(item: $editing) { cfg in
            NavigationStack {
                CustomRadioEditorView(config: cfg, options: options ?? .init(artists: [], tracks: [], genres: [], moods: [], activities: [], decades: [])) { saved in
                    let ok = await client.saveRadioConfig(saved)
                    if ok { await load(force: true) }
                    return ok
                }
            }
            #if os(macOS)
            .frame(minWidth: 460, minHeight: 620)
            #endif
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Label {
                LT("customRadio.headerTitle").font(.headline)
            } icon: {
                Image(systemName: "slider.horizontal.2.square").foregroundStyle(Color.roonGold)
            }
            LT("customRadio.headerSubtitle")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private func configRow(_ cfg: RadioConfig) -> some View {
        HStack(spacing: Spacing.md) {
            Button {
                Haptics.tap()
                editing = cfg
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(cfg.name.isEmpty ? LS("customRadio.unnamedRadio") : cfg.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(facetSummary(cfg))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(statusLine(cfg))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Toggle("", isOn: enabledBinding(cfg))
                .labelsHidden()
                .toggleStyle(.switch)
                .help(cfg.enabled ? LS("customRadio.radioOn") : LS("customRadio.radioOff"))
        }
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            Button {
                play(cfg)
            } label: { Label(LS("customRadio.play"), systemImage: "play.fill") }
            .tint(Color.roonGold)
            .disabled(!client.hasActiveOutput)
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { delete(cfg) } label: { Label(LS("action.delete"), systemImage: "trash") }
        }
    }

    private func facetSummary(_ cfg: RadioConfig) -> String {
        var parts: [String] = []
        if !cfg.artists.isEmpty { parts.append("\(cfg.artists.count) artiest\(cfg.artists.count == 1 ? "" : "en")") }
        if !cfg.trackKeys.isEmpty { parts.append("\(cfg.trackKeys.count) nummer\(cfg.trackKeys.count == 1 ? "" : "s")") }
        if !cfg.genres.isEmpty { parts.append(cfg.genres.prefix(3).map { $0.capitalized }.joined(separator: ", ")) }
        if !cfg.moods.isEmpty { parts.append(cfg.moods.prefix(3).map { RoonClient.moodLabel($0) }.joined(separator: ", ")) }
        if !cfg.activities.isEmpty { parts.append("\(cfg.activities.count) activiteit\(cfg.activities.count == 1 ? "" : "en")") }
        if !cfg.decades.isEmpty { parts.append(cfg.decades.sorted().map { "'\(String($0 % 100))" }.joined(separator: " ")) }
        return parts.isEmpty ? LS("customRadio.noSourceChosen") : parts.joined(separator: " · ")
    }

    private func statusLine(_ cfg: RadioConfig) -> String {
        var bits: [String] = [cfg.enabled ? LS("customRadio.statusOn") : LS("customRadio.statusOff")]
        if cfg.syncToQobuz {
            bits.append(cfg.qobuzPlaylistID != nil ? LS("customRadio.onQobuz") : LS("customRadio.awaitingSync"))
        } else {
            bits.append(LS("customRadio.notSyncing"))
        }
        return bits.joined(separator: " · ")
    }

    private func activeBanner(_ radio: RoonClient.RadioStatus) -> some View {
        VStack(spacing: Spacing.sm) {
            HStack(spacing: Spacing.md) {
                Image(systemName: "dot.radiowaves.left.and.right").font(.title3).foregroundStyle(Color.roonGold)
                VStack(alignment: .leading, spacing: 2) {
                    LT("customRadio.radioPlaying").font(.caption).foregroundStyle(.secondary)
                    Text(radio.artist).font(.headline)
                }
                Spacer()
                Button(role: .destructive) { Haptics.tap(); client.stopRadio() } label: {
                    Label(LS("customRadio.stop"), systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
            }
            RadioSteerField()
        }
        .cardStyle()
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "slider.horizontal.2.square").font(.largeTitle).foregroundStyle(.tertiary)
            LT("customRadio.emptyTitle").font(.headline)
            LT("customRadio.emptyBody")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Spacing.xl)
    }

    private func warningRow(_ text: String) -> some View {
        Label {
            Text(text).font(.caption)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.roonDanger)
        }
        .padding(Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.roonDanger.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.md))
    }

    // MARK: AI radios section

    @ViewBuilder
    private var aiSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(spacing: Spacing.sm) {
                Label {
                    LT("customRadio.aiRadiosTitle").font(.headline)
                } icon: {
                    Image(systemName: "sparkles").foregroundStyle(Color.roonGold)
                }
                if aiLoading { ProgressView().controlSize(.small) }
            }
            LT("customRadio.aiRadiosSubtitle")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let mgmt = aiMgmt {
                Toggle(LS("customRadio.syncToQobuz"), isOn: syncEnabledBinding)
                    .toggleStyle(.switch)
                    .font(.subheadline)

                Picker(LS("customRadio.category"), selection: $aiCategory) {
                    ForEach(RoonClient.manageableRadioCategories) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                let items = mgmt.radios.filter { $0.category == aiCategory.rawValue }
                if items.isEmpty {
                    Text(String(format: LS("customRadio.noneForCategory"), aiCategory.label.lowercased()))
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(items) { aiRow($0) }
                }
            } else if aiLoaded {
                LT("customRadio.noAIRadios")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().frame(maxWidth: .infinity).padding(.top, Spacing.sm)
            }
        }
        .cardStyle()
    }

    private func aiRow(_ item: AIRadioItem) -> some View {
        let hidden = aiMgmt?.radios.first { $0.id == item.id }?.hidden ?? item.hidden
        return HStack(spacing: Spacing.md) {
            AlbumArtView(imageKey: item.imageKey, size: 40, cornerRadius: Radius.sm)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(.subheadline).lineLimit(1)
                Text("\(item.label) · \(item.trackCount) tracks").font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .opacity(hidden ? 0.4 : 1)
            Spacer()
            Button {
                aiHiddenBinding(item).wrappedValue.toggle()
            } label: {
                Image(systemName: hidden ? "eye.slash" : "eye")
                    .foregroundStyle(hidden ? Color.secondary : Color.roonGold)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(hidden ? LS("customRadio.hiddenOnMain") : LS("customRadio.hideOnMain"))
            .help(hidden ? LS("customRadio.hiddenOnMain") : LS("customRadio.hideOnMain"))

            Button {
                Haptics.tap()
                editing = RoonClient.radioConfigFromAIRadio(item)
            } label: {
                Image(systemName: "square.and.pencil")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(LS("customRadio.adoptAsEditable"))
            .help(LS("customRadio.adoptAsEditable"))

            Toggle("", isOn: aiSelectedBinding(item))
                .labelsHidden()
                .toggleStyle(.switch)
                .help(item.selected ? LS("customRadio.willSync") : LS("customRadio.wontSync"))
        }
    }

    // MARK: Actions

    private func enabledBinding(_ cfg: RadioConfig) -> Binding<Bool> {
        Binding(
            get: { configs.first { $0.id == cfg.id }?.enabled ?? cfg.enabled },
            set: { newValue in
                Haptics.tap()
                var updated = cfg
                updated.enabled = newValue
                if let i = configs.firstIndex(where: { $0.id == cfg.id }) { configs[i] = updated }
                Task { await client.saveRadioConfig(updated) }
            }
        )
    }

    private func newConfig() {
        Haptics.tap()
        editing = RadioConfig(name: "")
    }

    private func play(_ cfg: RadioConfig) {

        Haptics.tap()
        Task { await client.startCustomRadio(cfg) }
    }

    private func delete(_ cfg: RadioConfig) {
        Haptics.tap()
        configs.removeAll { $0.id == cfg.id }
        Task { await client.deleteRadioConfig(id: cfg.id) }
    }

    private func load(force: Bool) async {
        guard force || !loaded else { return }
        isLoading = true
        defer { isLoading = false; loaded = true }
        if options == nil { options = await client.radioFacetOptions() }
        configs = await client.radioConfigs()
    }

    private func loadAI(force: Bool) async {
        guard force || !aiLoaded else { return }
        aiLoading = true
        defer { aiLoading = false; aiLoaded = true }
        aiMgmt = await client.aiRadioManagement()
    }

    private var syncEnabledBinding: Binding<Bool> {
        Binding(
            get: { aiMgmt?.syncEnabled ?? false },
            set: { on in
                Haptics.tap()
                aiMgmt?.syncEnabled = on
                Task { await client.setAIRadioSyncEnabled(on) }
            }
        )
    }

    private func aiSelectedBinding(_ item: AIRadioItem) -> Binding<Bool> {
        Binding(
            get: { aiMgmt?.radios.first { $0.id == item.id }?.selected ?? item.selected },
            set: { on in
                Haptics.tap()
                if let i = aiMgmt?.radios.firstIndex(where: { $0.id == item.id }) {
                    aiMgmt?.radios[i].selected = on
                }
                Task { await client.setAIRadioSelected(item.id, on) }
            }
        )
    }

    private func aiHiddenBinding(_ item: AIRadioItem) -> Binding<Bool> {
        Binding(
            get: { aiMgmt?.radios.first { $0.id == item.id }?.hidden ?? item.hidden },
            set: { on in
                Haptics.tap()
                if let i = aiMgmt?.radios.firstIndex(where: { $0.id == item.id }) {
                    aiMgmt?.radios[i].hidden = on
                }
                Task { await client.setAIRadioHidden(item.id, on) }
            }
        )
    }
}
