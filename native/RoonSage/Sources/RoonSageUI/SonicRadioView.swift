import RoonSageCore
import SwiftUI

/// Daily "for you" stations seeded from the artists you play most. Each card
/// starts an endless sonic radio that refills itself as it drains.
///
/// Built on `List` (used as a feed of self-styled cards via `.plainCardRow()`)
/// rather than a custom `ScrollView`/`VStack` — see `GenerateView` for why.
@MainActor
public struct SonicRadioView: View {
    @Environment(RoonClient.self) private var client
    @Environment(\.navigateTo) private var navigateTo
    @State private var category: RoonClient.RadioCategory = .artist
    @State private var radios: [RoonClient.SonicRadio] = []
    @State private var isLoading = false
    @State private var loaded = false

    // Smart-radio tuner (the "dial").
    @State private var adventurousness: Double = RoonClient.defaultAdventurousness
    @State private var hardBan = false

    // AI artist radios → Qobuz
    @State private var qobuzRadios: [RoonClient.SonicRadioPlaylist] = []
    @State private var isLoadingQobuz = false
    @State private var qobuzLoaded = false
    @State private var isSyncing = false
    @State private var syncMessage: String?
    @State private var detailPlaylist: RoonClient.SonicRadioPlaylist?
    @State private var showQobuzMirror = false
    @State private var keepMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: Spacing.md)]

    public init() {}

    public var body: some View {
        // Stations first. This screen used to open with a header repeating the
        // segment name, then a link to a DIFFERENT screen, then a slider that
        // only applies to the next station you start — three blocks, none of
        // them a station, which pushed the first tile to roughly 600 pt on an
        // 874 pt phone. You could not see a single station without scrolling.
        // Now the filter sits directly above what it filters, the stations come
        // next, and everything you rarely touch has moved below them.
        List {
            if let radio = client.activeRadio { activeBanner(radio).plainCardRow() }

            ZoneHintBanner().plainCardRow()

            categoryPicker.plainCardRow()

            AsyncStateView(isLoading: isLoading || !loaded, isEmpty: radios.isEmpty,
                           onRetry: { Task { await load(force: true) } }) {
                LazyVGrid(columns: columns, spacing: Spacing.md) {
                    ForEach(radios) { radioCard($0) }
                }
            } empty: {
                emptyState
            }
            .plainCardRow()

            if let keepMessage {
                Text(keepMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .plainCardRow()
                    .task {
                        try? await Task.sleep(for: .seconds(4))
                        self.keepMessage = nil
                    }
            }

            albumRadioCard.plainCardRow()

            myRadiosLink.plainCardRow()

            adventurousnessTuner.plainCardRow()

            qobuzSummary
                .task { await loadQobuz(force: false) }
                .plainCardRow()
        }
        .cardFeedList()
        .screenTitle(LS("sonicRadio.navTitle"))
        .toolbar {
            Button {
                Task { await load(force: true); await loadQobuz(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .accessibilityLabel(LS("a11y.refresh"))
            .help(LS("sonicRadio.refreshHelp"))
        }
        .task { await load(force: false) }
        .onAppear {
            adventurousness = client.radioAdventurousness
            hardBan = client.radioHardBanDisliked
        }
        .onChange(of: category) {
            // Only the daily radios above follow the picker; the Qobuz section shows
            // the full mirror across all categories, so it isn't reloaded here.
            Task { await load(force: true) }
        }
        .onChange(of: client.radioVisibilityRevision) {
            // Returned from "Mijn radio's" after hiding/showing a radio → re-filter.
            Task { await load(force: true) }
        }
        .sheet(item: $detailPlaylist) { playlistDetailSheet($0) }
        .navigationDestination(isPresented: $showQobuzMirror) {
            List { qobuzSection.plainCardRow() }
                .cardFeedList()
                .navigationTitle(LS("sonicRadio.qobuzTitle"))
        }
    }

    /// Switches both sections between Artiest · Genre · Sfeer · Activiteit · Decennium.
    /// A scrollable chip row rather than a segmented control: five labels don't
    /// fit an iPhone's width segmented (they clipped to "Activi…/Dece…").
    private var categoryPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Spacing.sm) {
                ForEach(RoonClient.RadioCategory.allCases) { c in
                    categoryChip(c)
                }
            }
            .padding(.horizontal, 2)
        }
    }

    @ViewBuilder
    private func categoryChip(_ c: RoonClient.RadioCategory) -> some View {
        let selected = c == category
        Button {
            Haptics.tap()
            withAnimation(Motion.quick) { category = c }
        } label: {
            Text(c.label)
                .font(.subheadline.weight(selected ? .semibold : .regular))
                .lineLimit(1)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
                .background(selected ? Color.roonGold.opacity(0.18) : Color.clear, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Color.roonGold : Color.secondary.opacity(0.35)))
                .foregroundStyle(selected ? Color.roonGold : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    // MARK: Sections

    /// Album Radio — an endless station grown around one album.
    ///
    /// Lives with the stations because that is what it is. It used to be one of
    /// three "journeys", between Time Machine and The Bridge, which both END —
    /// so the screen presented a station and two playlists as the same kind of
    /// thing. You start this one from an album, so the card's action takes you
    /// to your albums.
    private var albumRadioCard: some View {
        HStack(spacing: Spacing.md) {
            Image(systemName: "square.stack")
                .font(.title3)
                .foregroundStyle(Color.roonGold)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(LS("sonicJourneys.albumRadio")).font(.subheadline.weight(.semibold))
                Text(LS("sonicJourneys.albumRadioDesc"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Spacing.sm)
            Button {
                Haptics.tap()
                navigateTo(.library)
            } label: {
                Text(LS("sonicJourneys.browseAlbums"))
                    .font(.subheadline)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(.bordered)
            .buttonBorderShape(.capsule)
        }
        .cardStyle()
    }

    /// Entry point to the user-composed radios (create/edit/enable/sync). Pushed
    /// within the current navigation stack so both Mac and iOS reach it.
    private var myRadiosLink: some View {
        NavigationLink {
            CustomRadioView()
        } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: "slider.horizontal.2.square")
                    .font(.title3)
                    .foregroundStyle(Color.roonGold)
                VStack(alignment: .leading, spacing: 2) {
                    LT("sonicRadio.myRadiosTitle").font(.subheadline.weight(.semibold))
                    LT("sonicRadio.myRadiosSubtitle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardStyle()
    }





    /// The "dial" that turns every station from a cosy deep-cut hour into a
    /// voyage — biases the engine toward novelty/diversity and (optionally) hides
    /// thumbed-down tracks entirely. Applies to the next station you start.
    private var adventurousnessTuner: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack {
                Label(LS("sonicRadio.adventurousness"), systemImage: "slider.horizontal.3")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(adventureLabel).font(.caption).foregroundStyle(Color.roonGold)
            }
            Slider(value: $adventurousness, in: 0...1, step: 0.05)
                .tint(Color.roonGold)
                .onChange(of: adventurousness) { client.radioAdventurousness = adventurousness }
            HStack {
                Text(LS("sonicRadio.dialFamiliar")).font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Text(LS("sonicRadio.dialExploring")).font(.caption2).foregroundStyle(.tertiary)
            }
            SettingToggle(LS("sonicRadio.hideDisliked"), isOn: $hardBan)
                .padding(.top, Spacing.xs)
                .onChange(of: hardBan) { client.radioHardBanDisliked = hardBan }

            // The dial applies to the NEXT station you start, which nothing on
            // screen said — so moving it mid-listen looked broken. When a station
            // is running there IS a way to change it now: the steer field on the
            // active-radio banner, which is the same dial by another name.
            // Two spelled-out calls: check-localization.sh greps for
            // `LS("literal")` and cannot see a key chosen inside the call.
            Group {
                if client.activeRadio == nil {
                    Text(LS("sonicRadio.dialAppliesNext"))
                } else {
                    Text(LS("sonicRadio.dialSteerRunning"))
                }
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)

            // One visible truth: a persona OVERRIDES this slider, so say so where
            // the slider is instead of leaving two settings silently fighting.
            if let persona = client.stationPersona {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: persona.symbol).foregroundStyle(Color.roonGold)
                    Text(String(format: LS("stations.personaSteers"), persona.title))
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: Spacing.sm)
                    Button(LS("stations.personaClear")) {
                        Haptics.tap()
                        client.stationPersona = nil
                    }
                    .font(.caption)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.roonGold)
                }
                .padding(.top, Spacing.xs)
            }
        }
        .cardStyle()
    }

    private var adventureLabel: String {
        switch adventurousness {
        case ..<0.2:  return LS("sonicRadio.dialMostlyKnown")
        case ..<0.45: return LS("sonicRadio.dialLightExploring")
        case ..<0.7:  return LS("sonicRadio.dialAdventurous")
        default:      return LS("sonicRadio.dialExploring")
        }
    }

    private func activeBanner(_ radio: RoonClient.RadioStatus) -> some View {
        VStack(spacing: Spacing.sm) {
            HStack(spacing: Spacing.md) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.title3)
                    .foregroundStyle(Color.roonGold)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LS("sonicRadio.playing")).font(.caption).foregroundStyle(.secondary)
                    Text(radio.artist).font(.headline)
                }
                Spacer()
                Button(role: .destructive) {
                    Haptics.tap()
                    client.stopRadio()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
            }
            RadioSteerField()
        }
        .cardStyle()
    }

    private func radioCard(_ radio: RoonClient.SonicRadio) -> some View {
        Button {
            start(radio)
        } label: {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ZStack(alignment: .bottomTrailing) {
                    AlbumArtView(imageKey: radio.imageKey, size: 150, cornerRadius: Radius.lg)
                    Image(systemName: "play.circle.fill")
                        .font(.title)
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.roonGold)
                        .shadow(radius: 3)
                        .padding(Spacing.sm)
                }
                Text(radio.artist)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(String(format: LS("sonicRadio.trackCountLine"), radio.trackCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .disabled(!client.hasActiveOutput)
        .contextMenu { personaMenu(for: radio) }
    }

    /// "Start as …" — the six personas, plus the way back to the plain dial.
    @ViewBuilder
    private func personaMenu(for radio: RoonClient.SonicRadio) -> some View {
        Button {
            client.stationPersona = nil
            start(radio)
        } label: {
            Label(LS("stations.startPlain"), systemImage: "play.fill")
        }
        Divider()
        ForEach(DJMode.allCases, id: \.self) { mode in
            Button {
                start(radio, as: mode)
            } label: {
                Label(mode.title, systemImage: mode.symbol)
            }
        }
        Divider()
        // "Keep this one." An automatic station and a saved one were two
        // separate notions of the same thing; `RadioConfig.fromStation` maps
        // the first onto the second, so what you're hearing can become yours.
        Button {
            keep(radio)
        } label: {
            Label(LS("stations.keepThis"), systemImage: "plus.circle")
        }
    }

    /// Save the station you're looking at as an editable own station. The work
    /// is in Core: a station seeds on track ids and a config pins match keys,
    /// and translating between them needs the database.
    private func keep(_ radio: RoonClient.SonicRadio) {
        Haptics.tap()
        Task {
            if let name = await client.keepStationAsOwnRadio(radio) {
                keepMessage = String(format: LS("stations.keptAs"), name)
            } else {
                keepMessage = LS("stations.keepFailed")
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.largeTitle).foregroundStyle(.tertiary)
            Text(LS("sonicRadio.emptyTitle"))
                .font(.headline)
            Text(LS("sonicRadio.emptyBody"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, Spacing.xl)
    }

    // MARK: Actions

    /// Start a station, carrying whichever persona is set — the engine has always
    /// taken one here (`startRadio(_:zoneID:djMode:)`); nothing in the UI ever
    /// passed it.
    private func start(_ radio: RoonClient.SonicRadio, as persona: DJMode? = nil) {
        Haptics.tap()
        let mode = persona ?? client.stationPersona
        if let persona { client.stationPersona = persona }
        Task { await client.startRadio(radio, djMode: mode) }
    }

    private func load(force: Bool) async {
        guard force || !loaded else { return }
        isLoading = true
        defer { isLoading = false; loaded = true }
        // Drop radios the user hid from "Mijn radio's" (server-of-record set).
        let hidden = await client.hiddenRadioIDs()
        radios = await client.dailyRadios(category: category).filter { !hidden.contains($0.id) }
    }

    // MARK: AI artist radios → Qobuz

    private var llmConfigured: Bool {
        let c = LLMConfigStore.load()
        return c.provider == .ollama || !c.apiKey.isEmpty
    }

    @ViewBuilder
    /// The Qobuz mirror, folded into one line.
    ///
    /// It used to be a full second grid at the bottom of this screen: the same
    /// artists as the stations above it, under different (AI-generated) names,
    /// with their own sync button and warnings. Two lists of the same music on
    /// one screen, and nothing said they were the same music. Now: one line that
    /// says how many are mirrored, and the whole thing one tap away.
    private var qobuzSummary: some View {
        Button {
            Haptics.tap()
            showQobuzMirror = true
        } label: {
            HStack(spacing: Spacing.md) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.title3)
                    .foregroundStyle(Color.roonGold)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(LS("sonicRadio.qobuzTitle")).font(.subheadline.weight(.semibold))
                    Text(qobuzSummaryLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if isLoadingQobuz { ProgressView().controlSize(.small) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .cardStyle()
    }

    private var qobuzSummaryLine: String {
        if !client.qobuzConfigured { return LS("sonicRadio.qobuzNotConfigured") }
        if !qobuzLoaded && qobuzRadios.isEmpty { return LS("sonicRadio.qobuzLoading") }
        if qobuzRadios.isEmpty { return LS("sonicRadio.qobuzNoneYet") }
        return String(format: LS("sonicRadio.qobuzCount"), qobuzRadios.count)
    }

    /// The full mirror — pushed, so it costs a tap instead of half the screen.
    private var qobuzSection: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.sm) {
                    Label {
                        Text(LS("sonicRadio.qobuzTitle")).font(.headline)
                    } icon: {
                        Image(systemName: "square.stack.3d.up.fill").foregroundStyle(Color.roonGold)
                    }
                    if isLoadingQobuz { ProgressView().controlSize(.small) }
                }
                Text(LS("sonicRadio.qobuzBody"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !client.qobuzConfigured {
                warningRow(LS("sonicRadio.qobuzNotConfigured"))
            }
            if !llmConfigured {
                warningRow(LS("sonicRadio.noLLM"))
            }

            HStack(spacing: Spacing.md) {
                Button {
                    Task { await sync() }
                } label: {
                    Label(isSyncing ? LS("sonicRadio.syncing")
                        : String(format: LS("sonicRadio.syncToQobuz"), category.label),
                          systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.roonGold)
                .disabled(isSyncing || !client.qobuzConfigured)

                if isSyncing { ProgressView().controlSize(.small) }
            }

            if let syncMessage {
                Text(syncMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if !qobuzRadios.isEmpty {
                // Grouped by category (Artiest / Genre / …) so the full Qobuz mirror
                // is visible at once — no need to know the top category picker also
                // drove this section.
                ForEach(qobuzGroups, id: \.0) { cat, radios in
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        Text(cat.label)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                        LazyVGrid(columns: columns, spacing: Spacing.md) {
                            ForEach(radios) { qobuzCard($0) }
                        }
                    }
                }
            } else if isLoadingQobuz {
                ProgressView().frame(maxWidth: .infinity).padding(.top, Spacing.md)
            } else if qobuzLoaded {
                Text(LS("sonicRadio.qobuzEmpty"))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The mirrored radios bucketed by category, in the canonical category order,
    /// skipping empties — drives the grouped Qobuz grid.
    private var qobuzGroups: [(RoonClient.RadioCategory, [RoonClient.SonicRadioPlaylist])] {
        var byCat: [RoonClient.RadioCategory: [RoonClient.SonicRadioPlaylist]] = [:]
        for r in qobuzRadios {
            let cat = RoonClient.RadioCategory(radioID: r.id) ?? .artist
            byCat[cat, default: []].append(r)
        }
        return RoonClient.RadioCategory.allCases.compactMap { cat in
            guard let rs = byCat[cat], !rs.isEmpty else { return nil }
            return (cat, rs)
        }
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

    private func qobuzCard(_ radio: RoonClient.SonicRadioPlaylist) -> some View {
        Button {
            Haptics.tap()
            detailPlaylist = radio
        } label: {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ZStack(alignment: .topTrailing) {
                    AlbumArtView(imageKey: radio.imageKey, size: 150, cornerRadius: Radius.lg)
                    if radio.qobuzPlaylistID != nil {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.title3)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.roonGold)
                            .shadow(radius: 3)
                            .padding(Spacing.sm)
                    }
                }
                Text(radio.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text(radio.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                Text("\(radio.artist) · \(radio.tracks.count) tracks · \(radio.qobuzPlaylistID != nil ? "op Qobuz" : "nog niet gesynct")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.sm)
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.lg))
            .contentShape(RoundedRectangle(cornerRadius: Radius.lg))
        }
        .buttonStyle(.plain)
    }

    /// Detail sheet: the playlist's description, status, a "play now" action, and
    /// the full numbered tracklist. (Card tracks carry no artwork, so the list is
    /// number + title + artist — clean and scannable.)
    private func playlistDetailSheet(_ pl: RoonClient.SonicRadioPlaylist) -> some View {
        NavigationStack {
            List {
                Section {
                    Text(pl.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("\(pl.artist) · \(pl.tracks.count) tracks · \(pl.qobuzPlaylistID != nil ? "op Qobuz" : "nog niet gesynct")")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    if client.hasActiveOutput {
                        Button {
                            guard let z = client.selectedZone?.id else { return }
                            Haptics.tap()
                            Task { await client.curateTracks(pl.tracks, zoneID: z) }
                            detailPlaylist = nil
                        } label: {
                            Label("Speel nu", systemImage: "play.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.roonGold)
                    }
                }
                Section(LS("sonicRadio.tracksSection")) {
                    ForEach(Array(pl.tracks.enumerated()), id: \.offset) { i, t in
                        HStack(spacing: Spacing.sm) {
                            Text("\(i + 1).")
                                .foregroundStyle(.tertiary)
                                .frame(width: 28, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(t.title).lineLimit(1)
                                if let a = t.artist {
                                    Text(a).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                        }
                        .font(.callout)
                    }
                }
            }
            .navigationTitle(pl.title)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                Button(LS("sonicRadio.done")) { detailPlaylist = nil }
            }
        }
        .frame(minWidth: 440, minHeight: 540)
    }

    private func loadQobuz(force: Bool) async {
        guard force || !qobuzLoaded else { return }
        isLoadingQobuz = true
        defer { isLoadingQobuz = false; qobuzLoaded = true }
        qobuzRadios = await client.mirroredRadios()
    }

    private func sync() async {
        guard !isSyncing else { return }
        Haptics.tap()
        isSyncing = true
        syncMessage = nil
        defer { isSyncing = false }
        let count = await client.syncRadiosToQobuz(category: category)
        // Re-read the full mirror so cards reflect their new "op Qobuz" status.
        qobuzRadios = await client.mirroredRadios()
        qobuzLoaded = true
        if count > 0 {
            syncMessage = "\(count) radio('s) gesynchroniseerd naar Qobuz."
        } else if !client.qobuzConfigured {
            syncMessage = LS("sonicRadio.syncNotConfigured")
        } else if qobuzRadios.isEmpty {
            syncMessage = LS("sonicRadio.syncNothing")
        } else {
            syncMessage = LS("sonicRadio.syncFailed")
        }
    }
}
