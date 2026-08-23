import SwiftUI
import RoonSageCore

/// Connection gate shared by the macOS and iOS apps: shows the main interface
/// when connected to a Roon Core, otherwise the connect screen.
@MainActor
public struct ContentView: View {
    @Environment(RoonClient.self) private var client
    @State private var ambient = AmbientTheme()
    @State private var sleepTimer = SleepTimer()

    public init() {
        // Before any view can produce an error: Core's toasts are localised
        // through an injected translator (it can't reach this target's string
        // catalogue). Registering here rather than in an `onAppear` means a
        // failure during the very first connect is already translated.
        installCoreStringsTranslator()
    }

    public var body: some View {
        Group {
            // Stay on the main interface through transient poll blips once the
            // session is live — only a cold start or a deliberate disconnect
            // drops to the connect screen. Prevents a heavy generate stalling
            // /playback from tearing down views and losing in-flight state.
            // `plexStandalone` joins the escape hatches: a device signed in to
            // Plex with no RoonSage server has a complete library of its own, so
            // parking it on the connect screen would hide a working app behind a
            // server it does not need (user, 2026-08-23: "de analyzer is dus
            // optioneel"). Analyser-only features ask to connect where they live.
            if !client.plexOnboardingDone {
                // Altijd eerst, ook als Bonjour de server al gevonden heeft.
                WelcomeGate()
            } else if client.connectionState.isConnected || client.hasLiveSession
                || client.offlineMode || client.plexStandalone {
                // The banner is a layout SIBLING, not a top safe-area inset.
                //
                // As an inset it drew straight over the navigation toolbar: on
                // iOS 26 that toolbar floats as a capsule and kept its position,
                // so the gear (Instellingen), the output picker and the sync
                // button all sat behind the banner whenever the app was offline.
                // Measured, not guessed — the UI harness reported the gear at
                // y 66–102 in a window whose banner ran from 57 to 98.
                //
                // Same shape of fix as `nowPlayingBarDocked` at the bottom, and
                // for the same reason: a safe-area inset around a NavigationStack
                // is a suggestion, a VStack sibling is not.
                VStack(spacing: 0) {
                    OfflineBanner()
                    RootView()
                        .overlay(alignment: .top) { ReconnectingBanner() }
                }
            } else {
                WelcomeGate()
            }
        }
        .animation(Motion.standard, value: client.connectionState.isConnected)
        .animation(Motion.standard, value: client.hasLiveSession)
        .animation(Motion.standard, value: client.offlineMode)
        .animation(Motion.standard, value: client.plexOnboardingDone)
        .animation(Motion.standard, value: client.zonesAreStale)
        .overlay(alignment: .bottom) { ActionErrorToast() }
        // Summoned by AnalyzerRequiredNotice: on a standalone Plex device the
        // connect screen is no longer in the launch path, so a feature that needs
        // the server has to be able to call it up from where the user is.
        .sheet(isPresented: Bindable(client).showServerConnectSheet) {
            ConnectView()
        }
        .roonSageAppearance()
        .appLanguage()
        // Share the now-playing album-art tint with every tab, refreshed whenever
        // the current track's artwork changes.
        .environment(ambient)
        .environment(sleepTimer)
        .task(id: client.activeNowPlaying?.imageKey) { await ambient.update(from: client) }
    }
}

// MARK: - Welcome gate (first run)

/// Decides what a disconnected user sees:
///   - never connected before (`savedHost == nil`) → the `OnboardingView`
///     walkthrough, until they tap through to connect;
///   - already connected once, or mid-session after tapping "Verbinden" →
///     the `ConnectView` (discover / reconnect / manual entry).
///
/// Because `savedHost` is only persisted on a *successful* connect, a brand-new
/// user keeps seeing the welcome on every launch until they're actually
/// connected — then never again.
@MainActor
struct WelcomeGate: View {
    @Environment(RoonClient.self) private var client
    @State private var showConnect = false

    var body: some View {
        if showConnect || (client.plexOnboardingDone && client.savedHost != nil) {
            ConnectView()
                .transition(.opacity)
        } else {
            OnboardingView {
                // "Ik gebruik een RoonSage-server": de keuze is gemaakt, dus het
                // welkom is klaar — daarna is dit scherm het connect-scherm.
                client.completeOnboarding()
                withAnimation(Motion.standard) { showConnect = true }
            }
            .transition(.opacity)
        }
    }
}

// MARK: - Reconnecting banner

/// Thin top banner shown while the session is live but a poll blip has us
/// momentarily off `.connected`. Keeps the user informed without dropping the
/// whole UI to the connect screen (and discarding in-flight state).
@MainActor
struct ReconnectingBanner: View {
    @Environment(RoonClient.self) private var client

    var body: some View {
        // Only while genuinely establishing the first connection — once a live
        // session exists a poll blip must NOT drop a "Verbinden met …" pill over
        // the nav title (it was covering it and never clearing). Real failures
        // still surface via the bottom ActionErrorToast.
        //
        // And NOT in offline mode. There the connection state is permanently
        // `.failed`, so this pill sat over the search field forever, saying
        // "Fout: geen RoonSage-server gevonden" directly under a banner that had
        // already explained the situation calmly. Two messages about one fact,
        // one of them alarming and covering a control. Found on the first
        // screenshot the UI harness ever took — six batches of building never
        // surfaced it, because you have to *look*.
        if !client.connectionState.isConnected && !client.hasLiveSession && !client.offlineMode {
            pill(client.connectionState.label, icon: "arrow.clockwise")
        } else if client.zonesAreStale {
            // The other half of the zone-grace window, which had no voice at all.
            //
            // When the Roon link drops, Core deliberately KEEPS the last-known
            // zones for 45 s (`RoonClient.zoneGraceSeconds`) so a two-second blip
            // doesn't empty the picker and disable every play button. It marks
            // them `zonesAreStale` while it does — and until now not one view read
            // that flag. So the app looked entirely healthy: zones listed, zone
            // selected, transport enabled, and the only sign anything was wrong
            // was an error toast AFTER you pressed play. The pill above can't
            // cover it either, because `hasLiveSession` is still true here.
            pill(LS("root.zonesStale"), icon: "exclamationmark.triangle.fill")
        }
    }

    private func pill(_ text: String, icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

// MARK: - Offline banner

/// One honest line while there is no server.
///
/// Without it, offline mode is indistinguishable from "everything is broken":
/// the library browses fine, but a station or a sonic search silently fails
/// because those live on the analyzer. Say so once, at the top, instead of
/// letting the user discover it one dead button at a time.
@MainActor
struct OfflineBanner: View {
    @Environment(RoonClient.self) private var client
    @State private var retrying = false

    var body: some View {
        if client.offlineMode {
            HStack(spacing: Spacing.sm) {
                Image(systemName: "wifi.slash").font(.caption)
                Text(LS("offline.bannerText"))
                    .font(.caption).lineLimit(2)
                Spacer(minLength: Spacing.xs)
                Button {
                    retrying = true
                    Task {
                        await client.discoverAndConnect()
                        retrying = false
                    }
                } label: {
                    if retrying { ProgressView().controlSize(.mini) }
                    else { Text(LS("offline.retry")).font(.caption.weight(.semibold)) }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.roonGold)
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.xs)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
        }
    }
}

// MARK: - Action-error toast

/// Transient bottom toast for failed user actions (play/seek/volume/curate).
/// Driven by `RoonClient.lastActionError`; auto-dismisses after 4 seconds.
@MainActor
struct ActionErrorToast: View {
    @Environment(RoonClient.self) private var client
    @State private var visible = false
    @State private var dismissTask: Task<Void, Never>?

    var body: some View {
        Group {
            if visible, let err = client.lastActionError {
                Label(err.message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .lineLimit(2)
                    .padding(.horizontal, Spacing.lg)
                    .padding(.vertical, Spacing.md)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Radius.lg))
                    .overlay(
                        RoundedRectangle(cornerRadius: Radius.lg)
                            .strokeBorder(Color.roonDanger.opacity(0.5))
                    )
                    .padding(.horizontal, Spacing.xl)
                    .padding(.bottom, Spacing.xl)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(Motion.standard, value: visible)
        .onChange(of: client.lastActionError) { _, err in
            guard err != nil else { return }
            visible = true
            dismissTask?.cancel()
            dismissTask = Task {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else { return }
                visible = false
            }
        }
    }
}

// MARK: - Sidebar / tab destinations

public enum SidebarItem: String, CaseIterable, Identifiable {
    case nowPlaying  = "Now Playing"
    case queue       = "Queue"
    case library     = "Library"
    case ask         = "Vraag het"
    case generate    = "Generate"
    case recommend   = "Recommend"
    case playlists   = "Playlists"
    case bookmarks   = "Bookmarks"
    case djSet       = "DJ Set"
    case liveDJ      = "Live DJ"
    case djModes     = "DJ Modes"
    case dj          = "DJ"
    case stationsHub = "Stations"
    case radios      = "Radios"
    case journeys    = "Sonic Journeys"
    case fingerprint = "Sonic DNA"
    case musicMap    = "Music Map"
    case songPaths   = "Song Paths"
    case alchemy     = "Song Alchemy"
    case sonicSearch = "Sonic Search"
    case sonicLab    = "Sonic Lab"
    /// The power-tool drawer (Sonic Lab, Music Map, Multitag, DJ, taste).
    case lab         = "Lab"
    case multitag    = "Multitag"
    case discover    = "Discoveries"   // outward-facing recommendation engine ("Ontdekkingen")
    case discovery   = "Discovery"     // inward editorial "Listen Now" (library stats)
    case recent       = "Recent"
    case taste        = "Taste Profile"
    case tasteHub     = "Taste"
    case yearInReview = "Year in Review"
    case settings    = "Settings"

    public var id: String { rawValue }

    /// Weergavenaam (NL). rawValue blijft het stabiele ID; featurenamen
    /// (DJ Set, Live DJ, Sonic DNA, Music Map) blijven onvertaald.
    var title: String {
        switch self {
        case .nowPlaying:  LS("nav.nowPlaying")
        case .queue:       LS("nav.queue")
        case .library:     LS("nav.library")
        case .ask:         LS("nav.ask")
        case .generate:    LS("nav.generate")
        case .recommend:   LS("nav.recommend")
        case .playlists:   LS("nav.playlists")
        case .bookmarks:   LS("nav.bookmarks")
        case .djSet:       LS("nav.djSet")
        case .liveDJ:      LS("nav.liveDJ")
        case .djModes:     LS("nav.djModes")
        case .dj:          LS("nav.dj")
        case .stationsHub: LS("nav.stationsHub")
        case .radios:      LS("nav.radios")
        case .journeys:    LS("nav.journeys")
        case .fingerprint: LS("nav.fingerprint")
        case .musicMap:    LS("nav.musicMap")
        case .songPaths:   LS("nav.songPaths")
        case .alchemy:     LS("nav.alchemy")
        case .sonicSearch: LS("nav.sonicSearch")
        case .sonicLab:    LS("nav.sonicLab")
        case .lab:         LS("nav.lab")
        case .multitag:    LS("nav.multitag")
        case .discover:    LS("nav.discover")   // outward: music you don't own yet
        case .discovery:   LS("nav.discovery")
        case .recent:      LS("nav.recent")
        case .taste:       LS("nav.taste")
        case .tasteHub:    LS("nav.tasteHub")
        case .yearInReview: LS("nav.yearInReview")
        case .settings:    LS("nav.settings")
        }
    }

    var icon: String {
        switch self {
        case .nowPlaying:  "play.circle.fill"
        case .queue:       "list.number"
        case .library:     "music.note.list"
        case .ask:         "text.magnifyingglass"
        case .generate:    "wand.and.stars"
        case .recommend:   "sparkles.rectangle.stack"
        case .playlists:   "list.star"
        case .bookmarks:   "bookmark"
        case .djSet:       "slider.horizontal.3"
        case .liveDJ:      "slider.horizontal.2.gobackward"
        case .djModes:     "person.wave.2"
        case .dj:          "headphones"
        case .stationsHub: "antenna.radiowaves.left.and.right"
        case .radios:      "dot.radiowaves.left.and.right"
        case .journeys:    "map"
        case .fingerprint: "waveform.path.ecg"
        case .musicMap:    "map"
        case .songPaths:   "point.topleft.down.curvedto.point.bottomright.up"
        case .alchemy:     "wand.and.sparkles"
        case .sonicSearch: "sparkle.magnifyingglass"
        case .sonicLab:    "atom"
        case .lab:         "flask"
        case .multitag:    "tag"
        case .discover:    "wand.and.stars.inverse"
        case .discovery:   "sparkles"
        case .recent:      "clock.arrow.circlepath"
        case .taste:       "chart.radar"
        case .tasteHub:    "person.crop.circle"
        case .yearInReview: "calendar.badge.clock"
        case .settings:    "gearshape"
        }
    }
}

// MARK: - Cross-view navigation

/// Lets a deep view (e.g. an empty state) jump the sidebar/tab selection to
/// another destination — so "Genereer een playlist" from the Playlists empty
/// state actually takes the user to Generate instead of being a dead end.
public struct NavigateAction {
    let action: (SidebarItem) -> Void
    public func callAsFunction(_ item: SidebarItem) { action(item) }
}

private struct NavigateActionKey: EnvironmentKey {
    static let defaultValue = NavigateAction { _ in }
}

extension EnvironmentValues {
    public var navigateTo: NavigateAction {
        get { self[NavigateActionKey.self] }
        set { self[NavigateActionKey.self] = newValue }
    }
}

// MARK: - Sidebar grouping (macOS / iPad)

/// Groups the destinations into scannable, intent-based sections (Play /
/// Create / Stations / Explore / You), mirroring the iOS "Maak"/"Ontdek"
/// hubs so the macOS sidebar isn't one long flat list.
enum SidebarSection: String, CaseIterable, Identifiable {
    case playback, create, stations, explore, you, settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .playback: LS("section.playback")
        case .create:   LS("nav.search")
        case .stations: LS("section.stations")
        case .explore:  LS("section.explore")
        case .you:      LS("section.you")
        case .settings: LS("section.settings")
        }
    }

    /// The same five words the phone uses, in the same order.
    ///
    /// The sidebar listed 29 items while `detailView(for:)` only knows 13
    /// destinations, so more than half of them landed on a screen they didn't
    /// name — granularity the sidebar promised and couldn't deliver. Worse, it
    /// taught a different vocabulary than the tab bar, so the two platforms
    /// needed two mental models of the same app. This is the phone's shape with
    /// the desk's extra room: Now Playing and the queue earn their own rows here
    /// (there's a column to spare), everything else matches.
    var items: [SidebarItem] {
        switch self {
        case .playback: [.nowPlaying, .queue, .library, .playlists, .bookmarks]
        case .create:   [.sonicSearch]
        case .stations: [.stationsHub]
        case .explore:  [.discovery, .lab]
        case .you:      [.tasteHub]
        case .settings: [.settings]
        }
    }
}

// MARK: - Adaptive root

/// Adaptive navigation shell shared across platforms:
///   - regular width (macOS, iPad)  → `NavigationSplitView` with a sidebar
///   - compact width (iPhone)        → `TabView` (system shows a "More" tab past 5)
@MainActor
struct RootView: View {
    @Environment(RoonClient.self) private var client
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    #endif
    @Environment(SleepTimer.self) private var sleepTimer
    /// The library overview, not the player.
    ///
    /// Opening on Now Playing meant a cold start showed an EMPTY player: nothing
    /// is playing yet, no zone has been restored, and the first thing the app
    /// says is "niets aan het spelen". Plexamp and ARC both open on something you
    /// can act on. The last tab is remembered, so this default only ever applies
    /// to a genuinely first run.
    @State private var selection: SidebarItem = .library
    @State private var showPalette = false
    @State private var showShortcuts = false
    /// The player is presented OVER whatever you were doing (iPhone) rather than
    /// being a tab you switch to. See `playerSheet`.
    @State private var showPlayer = false
    /// Same for settings: a tab in the bar is prime real estate for a screen you
    /// visit twice a year. It's a gear on the library, and a sheet from here.
    @State private var showSettings = false
    /// A destination with no tab on a compact iPhone (the queue, playlists,
    /// bookmarks, the Lab tools, …), presented over the current tab. See
    /// `iOSTab(for:)` for why these can't just be a selection.
    @State private var destinationSheet: SidebarItem?
    /// Which page of the player sheet is showing: 0 the player, 1 the queue.
    @State private var playerPage = 0
    @AppStorage("lastTab") private var lastTabRaw: String = SidebarItem.library.rawValue
    @AppStorage("lastZoneID") private var lastZoneID: String = ""
    /// One-shot guard for the "restore the last zone" hook below.
    @State private var didRestoreZone = false

    /// `List` selection must be optional on iOS; the rest of the view keeps a
    /// non-optional `selection` (needed by `TabView`), so bridge the two.
    private var sidebarSelection: Binding<SidebarItem?> {
        Binding(get: { selection }, set: { if let v = $0 { selection = v } })
    }

    var body: some View {
        platformShell
            // The tappable now-playing mini-bar (local + zone) is attached
            // per-tab / to the split detail below, so it sits ABOVE the tab
            // buttons instead of floating over them.
            // Cmd/Ctrl+K opens the command palette from anywhere in the app.
            .background {
                ZStack {
                    Button("") { showPalette.toggle() }
                        .keyboardShortcut("k", modifiers: .command)
                    #if os(macOS)
                    // ⌘F — the reflex this app didn't answer.
                    //
                    // If the screen you're on already has a search field, put the
                    // cursor in it. If it doesn't, go to the one that does and
                    // focus it on the next runloop turn, once SwiftUI has built
                    // it. Both halves fail silently: the worst case is that ⌘F
                    // navigates and doesn't take focus, which is still better
                    // than nothing happening.
                    Button("") {
                        if SearchFieldFocus.focusKeyWindowSearchField() { return }
                        go(to: .library)
                        DispatchQueue.main.async { SearchFieldFocus.focusKeyWindowSearchField() }
                    }
                    .keyboardShortcut("f", modifiers: .command)
                    #endif
                }
                .opacity(0)
                .accessibilityHidden(true)
            }
            .sheet(isPresented: $showPalette) {
                paletteSheet
            }
            .sheet(isPresented: $showShortcuts) { ShortcutsCheatSheet() }
    }

    @ViewBuilder
    private var paletteSheet: some View {
        let palette = CommandPaletteView(
            navigate: { showPalette = false; go(to: $0) },
            showShortcuts: { showShortcuts = true }
        )
        #if os(iOS)
        palette.presentationDetents([.large])
        #else
        palette
        #endif
    }

    /// Every navigation request in the app goes through here.
    ///
    /// On the phone `.nowPlaying` is no longer a tab, so it can't be a selection:
    /// it raises the player over whatever you were doing. Funnelling it means the
    /// mini-bar, the command palette and any empty-state button all keep working
    /// without knowing which shell they're in — on macOS/iPad the sidebar item
    /// still exists and this stays a plain selection.
    ///
    /// The same reasoning had to be extended to every OTHER tabless destination.
    /// `iOSTabSelection` maps an arbitrary item onto one of four tags, and
    /// anything it didn't recognise fell into a `default` that returned
    /// `.library`. The command palette offers seventeen "Ga naar …" commands, so
    /// nine of them — Wachtrij, Playlists, Bewaard, DJ, Lab, Sonic Lab, Music
    /// Map, Multitag, Smaak — set a selection no tab answered to and silently
    /// landed you on the library. `Self.iOSTab(for:)` now returns nil instead of
    /// guessing, and nil means "present it", exactly like the player and settings.
    private func go(to item: SidebarItem) {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            switch item {
            case .nowPlaying: playerPage = 0; showPlayer = true; return
            case .settings:   showSettings = true; return
            default:
                if Self.iOSTab(for: item) == nil { destinationSheet = item; return }
            }
        }
        #endif
        selection = item
    }

    /// Restore the tab you were last on. Guards against a value persisted by an
    /// older build (or reached through a sheet) that has no tab on the phone —
    /// restoring one of those would leave the selection pointing at a tag the
    /// TabView cannot show, and re-raise a sheet you closed last session.
    private func restoreLastTab() {
        guard let item = SidebarItem(rawValue: lastTabRaw) else { return }
        #if os(iOS)
        if horizontalSizeClass == .compact, Self.iOSTab(for: item) == nil { return }
        #endif
        selection = item
    }

    @ViewBuilder
    private var platformShell: some View {
        #if os(iOS)
        if horizontalSizeClass == .compact {
            tabView
        } else {
            splitView
        }
        #else
        splitView
        #endif
    }

    // MARK: Split (macOS / iPad)

    private var splitView: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                ForEach(SidebarSection.allCases) { section in
                    Section(section.title) {
                        ForEach(section.items) { item in
                            Label(item.title, systemImage: item.icon)
                                .tag(item)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)

            Divider()
            connectedBadge
        } detail: {
            // Give the detail column its OWN NavigationStack — matching the iOS
            // tab shells — instead of leaning on NavigationSplitView's implicit
            // one. Two bugs this fixes on macOS/iPad:
            //   1. A per-screen `.toolbar` in a bare split-view detail is
            //      shadowed by the split view's own toolbar: the buttons render
            //      (a Menu even opens) but their actions never reach the detached
            //      detail view, so "Ontdek-inzichten"/"Ontdek op stemming" looked
            //      dead. Hosting the detail in its own NavigationStack gives that
            //      toolbar a real owner, like the working iOS path.
            //   2. A pushed NavigationLink (Herontdek → "Ontdek Wekelijks") stayed
            //      on top when the sidebar changed, freezing the detail.
            // `.id(selection)` rebuilds the stack per sidebar item, so a push is
            // discarded on switch and the new root always shows.
            NavigationStack {
                detailView(for: selection)
                    .ambientSurface()
                    // Mini-bar above the window bottom — hidden on Now Playing,
                    // which already hosts the full hero + transport.
                    .nowPlayingBarInset(hidden: selection == .nowPlaying)
            }
            // Placed inside the navigateTo environment so a mini-bar / empty-state
            // tap can switch tabs.
            .environment(\.navigateTo, NavigateAction { go(to: $0) })
            .id(selection)
        }
        .navigationTitle("")
        .toolbar { navToolbar }
        .background { tabShortcuts }
        .onChange(of: client.zones) { _, _ in restoreLastZoneOnce() }
        .onAppear { restoreLastTab() }
        .onChange(of: selection) { _, item in lastTabRaw = item.rawValue }
        .task { await autoPullFromServerIfEmpty() }
    }

    /// Restore the last-used zone once the zone list arrives — and ONLY then.
    ///
    /// Two bugs lived in the old inline version. It fired on every `zones`
    /// change (which is every track change, every play/pause, and — while the
    /// connection was flapping — every two seconds), and it didn't look at
    /// `localOutputSelected`. So picking "dit apparaat" held for exactly as long
    /// as it took the next zone update to arrive, at which point `selectZone`
    /// silently switched the output back to Roon. Restoring is a launch-time
    /// convenience, so it happens at most once per session and never overrides
    /// on-device output.
    private func restoreLastZoneOnce() {
        guard !didRestoreZone, !client.localOutputSelected,
              client.selectedZone == nil, !lastZoneID.isEmpty,
              client.zones.contains(where: { $0.id == lastZoneID })
        else { return }
        didRestoreZone = true
        client.selectZone(lastZoneID)
    }

    /// First-run convenience: when the local library is still empty, pull
    /// everything (settings + library + analyses) from the central server once,
    /// so a fresh client configures itself without manual steps. Existing data
    /// is left untouched — refreshing later is manual via Settings → Server.
    private func autoPullFromServerIfEmpty() async {
        guard client.trackCount == 0, !client.isSyncing else { return }
        _ = await client.autoSyncEverythingFromServer()
    }

    // MARK: Tabs (iPhone) — iOS only
    //
    // Four tabs, and every one of them lands on content.
    //
    // It used to be five, of which three weren't destinations at all: "Maak" and
    // "Ontdek" were `List`s whose only job was to link to a hub that then showed
    // a segmented control, and "Instellingen" was a screen of 21 sections in the
    // prime row of the app. Two taps of navigation furniture before anything
    // played. What lived in those cupboards didn't go anywhere — it moved one
    // level UP (Ontdek and Stations are now the hubs themselves) or one level
    // sideways (Lab, playlists and bookmarks are cards on the library; settings
    // is a gear).

    #if os(iOS)
    private var tabView: some View {
        TabView(selection: iOSTabSelection) {
            NavigationStack {
                LibraryView()
                    // NOT an LS key with the count interpolated into it. That bakes the
                    // number INTO the key, so it can never resolve and silently
                    // renders the Dutch literal — the app's main heading stayed
                    // Dutch on an English phone while everything under it
                    // translated. Photographed by the UI harness; there are ~70
                    // more of these, see check-localization.sh.
                    .navigationTitle(String(format: LS("library.titleWithCount"), client.trackCount))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { navToolbar }
                    .toolbar { settingsToolbarItem }
                    .ambientSurface()
            }
            .nowPlayingBarDocked()
            .tabItem { Label { LT("nav.library") } icon: { Image(systemName: "music.note.list") } }
            .tag(SidebarItem.library)

            NavigationStack {
                SearchView()
                    .navigationTitle(LS("nav.search"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { navToolbar }
                    .ambientSurface()
            }
            .nowPlayingBarDocked()
            .tabItem { Label { LT("nav.search") } icon: { Image(systemName: "magnifyingglass") } }
            .tag(SidebarItem.sonicSearch)

            NavigationStack {
                DiscoverHubView()
                    .navigationTitle(LS("section.explore"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { navToolbar }
                    .ambientSurface()
            }
            .nowPlayingBarDocked()
            .tabItem { Label { LT("section.explore") } icon: { Image(systemName: "sparkles") } }
            .tag(SidebarItem.discovery)

            NavigationStack {
                StationsHubView()
                    .navigationTitle(LS("section.stations"))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { navToolbar }
                    .ambientSurface()
            }
            .nowPlayingBarDocked()
            .tabItem { Label { LT("section.stations") } icon: { Image(systemName: "dot.radiowaves.left.and.right") } }
            .tag(SidebarItem.stationsHub)
        }
        .onChange(of: client.zones) { _, _ in restoreLastZoneOnce() }
        .environment(\.navigateTo, NavigateAction { go(to: $0) })
        .onAppear { restoreLastTab() }
        .onChange(of: selection) { _, item in lastTabRaw = item.rawValue }
        .sheet(isPresented: $showPlayer) { playerSheet }
        .sheet(isPresented: $showSettings) { settingsSheet }
        .sheet(item: $destinationSheet) { destinationSheetView($0) }
        .task { await autoPullFromServerIfEmpty() }
    }

    /// The gear, on the library — the tab you open most, so the one place a
    /// settings entry is always within reach without costing a tab.
    @ToolbarContentBuilder
    private var settingsToolbarItem: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel(LS("nav.settings"))
            // Language-independent handle for the UI walk: every visible label
            // in this app is localised, and a test that matches on Dutch would
            // pass or fail on the device's language rather than on the UI.
            .accessibilityIdentifier("gear.settings")
        }
    }

    private var settingsSheet: some View {
        NavigationStack {
            SettingsHomeView()
                .navigationTitle(LS("nav.settings"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(LS("lyrics.done")) { showSettings = false }
                    }
                }
        }
    }

    /// The player, raised over whatever you were doing.
    ///
    /// It used to be the first tab, so tapping the mini-bar threw you out of the
    /// library and losing your place was the price of a glance at the artwork.
    /// Plexamp and ARC both slide the player up as a card you flick away again;
    /// that is the whole point of this change.
    ///
    /// A `.sheet` (not a `fullScreenCover`) because it dismisses on a downward
    /// swipe for free, and `presentationDragIndicator(.visible)` says so without
    /// spending a corner on a close button.
    private var playerSheet: some View {
        NavigationStack {
            // Two pages: the player, and the queue one swipe to the left. The
            // queue has no tab on the phone — it lives TO what's playing, so it
            // travels with the player instead of being a destination. The
            // selection binding is what lets the player's queue button page here
            // rather than stack another sheet on this one.
            TabView(selection: $playerPage) {
                NowPlayingView().tag(0)
                QueueView()
                    .navigationBarTitleDisplayMode(.inline)
                    .tag(1)
            }
            // No page dots. The index view renders as a capsule pinned to the
            // bottom centre — right on top of the feedback row — so it swallowed
            // taps meant for the thumbs and the «…» menu and paged to the queue
            // instead. A control that blocks the controls beneath it is worse
            // than an undiscoverable gesture.
            .tabViewStyle(.page(indexDisplayMode: .never))
            // Immersive: no toolbar here. The zone picker + mini-transport are
            // useful on list screens but compete with the player's own output
            // strip and large transport.
            .toolbar(.hidden, for: .navigationBar)
            .ignoresSafeArea(.keyboard)
        }
        // The empty-state buttons ("Ontdek muziek", "Maak een playlist") point at
        // tabs BEHIND this sheet, so they have to close it first — otherwise you
        // tap them and nothing appears to happen.
        .environment(\.navigateTo, NavigateAction { item in
            showPlayer = false
            go(to: item)
        })
        .environment(\.showQueue, { withAnimation(Motion.standard) { playerPage = 1 } })
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    /// Which of the four tabs a destination belongs to — **nil when it has none**.
    ///
    /// The command palette can ask for any of the 29 `SidebarItem`s by name, and
    /// a `TabView` selection with no matching tag renders a BLANK tab, so every
    /// item does have to resolve to something. It used to resolve here, with a
    /// `default` that answered `.library` for everything it didn't recognise —
    /// which turned nine palette commands into no-ops that dropped you on the
    /// library. Answering nil instead lets `go(to:)` present those destinations
    /// rather than pretending they are a tab; `.nowPlaying` and `.settings` never
    /// reach here at all, they were already sheets.
    static func iOSTab(for item: SidebarItem) -> SidebarItem? {
        switch item {
        case .library:                     .library
        case .sonicSearch, .ask:           .sonicSearch
        case .discover, .discovery:        .discovery
        case .stationsHub, .radios, .journeys, .djModes, .generate, .recommend:
                                           .stationsHub
        default:                           nil
        }
    }

    private var iOSTabSelection: Binding<SidebarItem> {
        Binding(
            // A tabless destination is showing as a sheet OVER the library, so
            // that is the tab that should stay lit underneath it.
            get: { Self.iOSTab(for: selection) ?? .library },
            set: { selection = $0 }
        )
    }

    /// A destination that has no tab, raised over the current one.
    ///
    /// Same shape as `playerSheet` and `settingsSheet`, and for the same reason:
    /// on a four-tab phone the alternative to presenting is not presenting.
    private func destinationSheetView(_ item: SidebarItem) -> some View {
        NavigationStack {
            detailView(for: item)
                .ambientSurface()
                .navigationTitle(item.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(LS("lyrics.done")) { destinationSheet = nil }
                    }
                }
        }
        .nowPlayingBarDocked()
        // Anything reached from in here (an empty state's "Maak een playlist")
        // points at a tab BEHIND this sheet, so close it first.
        .environment(\.navigateTo, NavigateAction { next in
            destinationSheet = nil
            go(to: next)
        })
    }
    #endif

    // MARK: Shared destination switch

    @ViewBuilder
    private func detailView(for item: SidebarItem) -> some View {
        switch item {
        case .nowPlaying:  NowPlayingView()
        case .queue:       QueueView()
        case .library:     LibraryView()
        case .ask, .generate, .recommend: CreateHubView()
        case .playlists:   PlaylistsView()
        case .bookmarks:   BookmarksView()
        // Analyser-only. Gated here rather than inside each screen so the feature
        // views stay untouched and the rule lives in one place.
        //
        // Stations are NOT gated: with `plex_sonic_enabled` they run off Plex's
        // own Sonic Analysis, so they degrade rather than disappear.
        case .djSet, .liveDJ, .dj:
            DJView().requiresAnalyzer(
                client, feature: "DJ-sets",
                reason: "Harmonisch mixen vraagt BPM en toonsoort per nummer. Plex meet die niet — de analyzer wel.")
        case .stationsHub, .radios, .journeys, .djModes: StationsHubView()
        case .musicMap:
            MusicMapView().requiresAnalyzer(
                client, feature: "Muziekkaart",
                reason: "De kaart tekent je bibliotheek uit de audio-embeddings van de analyzer.")
        case .songPaths, .alchemy, .sonicLab:
            SonicLabView().requiresAnalyzer(
                client, feature: "Sonisch lab",
                reason: "Song Paths en Song Alchemy rekenen met de audiovectoren van de analyzer. Plex geeft die niet vrij.")
        case .sonicSearch: SearchView()
        case .lab:         LabView()
        case .multitag:    MultitagView()
        case .discover, .discovery: DiscoverHubView()
        case .fingerprint, .recent, .taste, .tasteHub, .yearInReview: TasteHubView()
        case .settings:    SettingsHomeView()
        }
    }

    private var connectedBadge: some View {
        let connected = client.connectionState.isConnected
        return HStack(spacing: 6) {
            Circle().fill(connected ? Color.roonSuccess : Color.roonDanger)
                .frame(width: 8, height: 8)
            Text(client.connectionState.label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(String(format: LS("a11y.connection"), client.connectionState.label))
    }

    /// Cmd+1…9 jump straight to a sidebar row. Hidden but active (hardware keyboard).
    ///
    /// Numbered off `SidebarSection.items` — what the sidebar actually shows, in
    /// the order it shows it. It used to be `SidebarItem.allCases.prefix(9)`,
    /// which is declaration order in an enum of 29 cases and has nothing to do
    /// with the sidebar: ⌘4/5/6/9 landed on Vraag het, Genereer, Aanbevelingen and
    /// DJ Set — four destinations with no row to highlight — while ⌘7/⌘8 hit rows
    /// 4 and 5. A keyboard shortcut that doesn't match the menu it shadows is
    /// worse than none, because you learn it wrong.
    private var tabShortcuts: some View {
        let rows = SidebarSection.allCases.flatMap(\.items).prefix(9)
        return ZStack {
            ForEach(Array(rows.enumerated()), id: \.offset) { idx, item in
                Button("") { go(to: item) }
                    .keyboardShortcut(KeyEquivalent(Character("\(idx + 1)")), modifiers: .command)
            }
        }
        .opacity(0)
        .accessibilityHidden(true)
    }

    // MARK: Toolbar (zone picker + mini transport)

    @ToolbarContentBuilder
    private var navToolbar: some ToolbarContent {
        if !client.zones.isEmpty {
            #if os(macOS)
            ToolbarItem(placement: .navigation) { zonePicker }
            #else
            ToolbarItem(placement: .topBarLeading) { zonePicker }
            #endif
        }
        if sleepTimer.isActive, let endsAt = sleepTimer.endsAt {
            ToolbarItem(placement: .automatic) {
                Button { sleepTimer.cancel() } label: {
                    Label(endsAt.formatted(date: .omitted, time: .shortened), systemImage: "moon.zzz.fill")
                        .font(.caption)
                        .foregroundStyle(Color.roonGold)
                }
                .help(String(format: LS("root.sleepTimerActiveUntil"), endsAt.formatted(date: .omitted, time: .shortened)))
            }
        }
        ToolbarItem(placement: .automatic) {
            Button { showPalette = true } label: {
                Image(systemName: "command")
            }
            .accessibilityLabel(LS("root.commandPalette"))
            .help(LS("root.commandPaletteHelp"))
        }
        if let zone = client.selectedZone {
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    Task { await client.previous(zoneID: zone.id) }
                } label: { Image(systemName: "backward.fill") }
                    .accessibilityLabel(LS("root.previousTrack"))
                    .help(LS("root.previousTrack"))

                Button {
                    Task { await client.playPause(zoneID: zone.id) }
                } label: { Image(systemName: zone.state == .playing ? "pause.fill" : "play.fill") }
                    .accessibilityLabel(zone.state == .playing ? LS("root.pause") : LS("root.play"))
                    .help(zone.state == .playing ? LS("root.pause") : LS("root.play"))

                Button {
                    Task { await client.next(zoneID: zone.id) }
                } label: { Image(systemName: "forward.fill") }
                    .accessibilityLabel(LS("root.nextTrack"))
                    .help(LS("root.nextTrack"))
            }
        }
    }

    /// The output picker in the toolbar.
    ///
    /// This used to be a third hand-built copy of the destination menu, next to
    /// `OutputSelector` and the one in `AIComponents` — and the three had already
    /// drifted apart in icon logic and ordering. It's the shared control now; the
    /// menu itself lives in `OutputMenuContent`.
    private var zonePicker: some View { OutputSelector() }
}
