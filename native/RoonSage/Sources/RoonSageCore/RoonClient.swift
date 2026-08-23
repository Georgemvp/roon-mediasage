import AudioAnalysis
import Foundation
import Observation
import RoonProtocol

/// Top-level observable client. Drives UI state and owns the transport actor.
///
/// All mutations happen on the MainActor so SwiftUI observations are safe.
/// The transport actor handles WebSocket I/O on its own executor.
@MainActor
@Observable
public final class RoonClient {

    /// Process-wide instance. App Intents (Siri/Shortcuts, Live Activity
    /// buttons) run in the app process without access to SwiftUI state, so
    /// they need a reachable client. The apps use this same instance.
    public static let shared = RoonClient()

    // MARK: - Connection state

    public enum ConnectionState: Equatable {
        case disconnected
        case discovering
        case connecting(host: String)
        case awaitingAuthorization
        case connected(coreName: String)
        case failed(String)

        public var label: String {
            switch self {
            case .disconnected:              "Niet verbonden"
            case .discovering:               "Zoeken naar Roon Core…"
            case .connecting(let host):      "Verbinden met \(host)…"
            case .awaitingAuthorization:     "Wacht op goedkeuring in Roon…"
            case .connected(let name):       "Verbonden met \(name)"
            case .failed(let msg):           "Fout: \(msg)"
            }
        }

        public var isConnected: Bool {
            if case .connected = self { return true }
            return false
        }

        /// Mid-handshake: discovering a Core, or opening/authorizing a socket.
        /// Drives the "connecting" spinner + reconnect affordance in the UI.
        public var isBusy: Bool {
            switch self {
            case .discovering, .connecting, .awaitingAuthorization: return true
            default: return false
            }
        }
    }

    // MARK: - Sync state

    public struct SyncProgress: Equatable {
        public var phase: String
        public var albumsCompleted: Int
        public var albumsTotal: Int
        public var tracksFound: Int
        public var fraction: Double { albumsTotal > 0 ? Double(albumsCompleted) / Double(albumsTotal) : 0 }
    }

    // MARK: - Observable state

    /// True once the session has reached `.connected` and the user hasn't
    /// deliberately disconnected. The UI gate (`ContentView`) keeps the main
    /// interface up while this is set, so a transient poll blip — e.g. a heavy
    /// generate (Ollama on the server) or a long curate queue-load stalling
    /// `/playback` — doesn't tear down live views and discard in-flight state
    /// like a freshly generated playlist. Cleared only on an intentional
    /// disconnect; the background poll loop keeps retrying meanwhile.
    public internal(set) var hasLiveSession = false

    /// Bumped whenever a radio is hidden/shown from "Mijn radio's", so the main
    /// Radio's screen re-filters its tiles the moment the user returns (the
    /// `radioHidden` set itself is UserDefaults-backed and not observable).
    public internal(set) var radioVisibilityRevision = 0

    public internal(set) var connectionState: ConnectionState = .disconnected {
        didSet {
            if connectionState.isConnected {
                hasLiveSession = true
                offlineMode = false
            }
            // A failed attempt with a synced library on disk means offline, not
            // broken. Slide into offline mode rather than leaving the user on a
            // connect screen with a phone full of music they can't reach.
            if case .failed = connectionState, !hasLiveSession, hasLocalLibrary {
                enterOfflineMode()
            }
        }
    }
    public internal(set) var zones: [Zone] = []

    /// Last.fm historie-import voortgang (zie `RoonClient+Lastfm`).
    public internal(set) var lastfmImportInProgress = false
    public internal(set) var lastfmImportStatus = ""

    public struct QueueItem: Sendable, Identifiable, Codable {
        public var id: Int
        public var title: String
        public var subtitle: String?
        public var length: Int
        public var imageKey: String?
    }
    public internal(set) var queueItems: [QueueItem] = []
    var queueTask: Task<Void, Never>?
    /// Zone the queue is currently subscribed to (idempotent re-subscribe).
    var queueZoneID: String?

    // MARK: - Track feedback (like / dislike — see RoonClient+Feedback)
    /// In-memory verdicts keyed by content match_key, mirrored from the
    /// server-of-record. Observed by Now Playing so a thumb lights up instantly;
    /// read by the radio / fingerprint / recommendation builders so they learn.
    public internal(set) var feedbackByMatchKey: [String: TrackFeedbackKind] = [:]
    /// Whether `feedbackByMatchKey` has been populated this session.
    var feedbackLoaded = false
    /// Content keys skipped repeatedly (implicit dislike) — loaded alongside the
    /// explicit verdicts, merged into the radio dislike set but NOT shown as
    /// thumbs-down in the feedback UI. Server-of-record; empty on thin clients.
    var heavilySkippedKeys: Set<String> = []

    // MARK: - Favorites (starred albums / artists — see RoonClient+Favorites)
    /// In-memory favorites keyed "kind␟key", mirrored from the server-of-record.
    public internal(set) var favoriteKeys: Set<String> = []
    /// Whether `favoriteKeys` has been populated this session.
    var favoritesLoaded = false

    // MARK: - Bookmarks ("Bewaar voor later" — see RoonClient+Bookmarks)
    /// In-memory bookmark keys "kind␟key", mirrored from the server-of-record,
    /// so the bookmark toggle lights up instantly across views.
    public internal(set) var bookmarkKeys: Set<String> = []
    /// The full bookmark list for the dedicated view (kept in sync with the mirror).
    public internal(set) var bookmarks: [DatabaseManager.BookmarkEntry] = []
    /// Whether the bookmark set has been populated this session.
    var bookmarksLoaded = false

    // MARK: - Sonic Radio (endless, artist-seeded — see RoonClient+Radio)
    /// The currently-running endless radio, if any. Drives the "playing" banner.
    public internal(set) var activeRadio: RadioStatus?
    /// Internal run state of the active radio (candidate pool + cursor). Not
    /// observed by the UI; only `activeRadio` is.
    var radioState: RadioRunState?
    /// Single-flight guard: a pool regeneration (top-up exhaustion OR a live
    /// re-steer) is in flight. Prevents the 3s monitor and a thumb-driven re-steer
    /// from interleaving their read-modify-write of `radioState` across awaits.
    var radioRegenerating = false
    /// Polls the queue depth and tops the station up when it runs low.
    var radioMonitorTask: Task<Void, Never>?
    /// Guest-DJ autoplay guards: an in-flight launch, and the last now-playing
    /// title we attempted from — so a track that can't seed a station (e.g. not
    /// yet analyzed) is tried once, not on every zone frame.
    var autoplayInFlight = false
    var lastAutoplayTitle: String?
    // The periodic server jobs (AI-radio → Qobuz, discovery run, weekly digest,
    // Ontdek Wekelijks, feature sync, Last.fm scrobbles) used to each keep a
    // retained `Task` here. They now live in `TaskScheduler`, which owns their
    // drivers and their persisted cadence — see TaskScheduler.swift.
    /// Guards against overlapping pipeline runs (a manual /discovery/run while the
    /// scheduled one is mid-flight).
    var discoveryRunning = false
    /// The last successfully synced set of AI radios, keyed by `RadioCategory`
    /// rawValue. Served to client apps via /artist-radios?category=… so iOS/macOS
    /// always show the same playlists as Qobuz.
    var cachedArtistRadios: [String: [SonicRadioPlaylist]] = [:]
    /// The last built/loaded weekly discovery playlist, served to client apps via
    /// /discover-weekly so iOS/macOS always show the same set as the server.
    var cachedDiscoverWeekly: DiscoverWeeklyPlaylist?

    // MARK: - Control mode (playback proxy)
    /// `.direct` = talk to Roon over the WebSocket (the server build).
    /// `.server` = talk to the RoonSage server over HTTP (the client apps);
    /// no Roon extension is registered. Set once at launch via `useServerMode()`.
    public internal(set) var controlMode: RoonControlMode = .direct
    var isRemote: Bool { controlMode == .server }
    /// Resolved server base URL (e.g. http://10.94.184.22:5767) in server mode.
    var remoteBaseURL: String?
    var remotePollTask: Task<Void, Never>?
    /// The long-lived `GET /events` subscription that replaced most of the poll
    /// traffic (see RoonClient+Remote). Nil when not in server mode.
    var remoteEventTask: Task<Void, Never>?
    /// When the event stream last delivered anything (snapshot or keepalive). The
    /// poll uses this to decide whether it is the primary path or a safety net.
    var lastPlaybackEventAt: Date?
    /// Consecutive failed/degraded polls; the UI only drops the connection after
    /// a few in a row so a single blip doesn't bounce to the connect screen.
    var remotePollFailures = 0
    /// Guards against overlapping auto library re-imports while one is running.
    var isImportingFromServer = false
    /// Guards against overlapping re-discoveries triggered by failed polls
    /// (network switch: the poll loop keeps failing while one runs).
    var isRediscovering = false
    /// One-shot guard so the lyrics backfill trickle starts at most once per launch.
    var lyricsBackfillStarted = false
    /// Re-issues the zones subscription when its initial state never arrives.
    var zonesWatchdog: Task<Void, Never>?

    /// Last failed user action — drives a transient toast in the UI. Each
    /// failure gets a fresh `id` so repeated identical messages retrigger
    /// the toast. Transport commands used to swallow errors silently: the
    /// user tapped Play mid-reconnect and nothing happened, with no feedback.
    public struct ActionError: Equatable, Sendable {
        public let id: UUID
        public let message: String
        public init(message: String) {
            self.id = UUID()
            self.message = message
        }
    }
    public internal(set) var lastActionError: ActionError?

    /// Result of the most recent "play on this device" attempt — how many tracks
    /// were locally playable vs. skipped (Qobuz/streaming-only). Drives the
    /// filter notice in the local-playback UI.
    public internal(set) var lastLocalPlaybackSummary: LocalPlaybackSummary?

    /// Surface a failure from a feature/compute view (DJ set, Sonic DNA, Song
    /// Paths, Music Map, …) in the global error toast, so a failed computation
    /// reads as "something went wrong" instead of a misleading empty state.
    public func reportError(_ message: String) {
        lastActionError = ActionError(message: message)
    }

    /// Run a fire-and-forget user action against the transport service,
    /// surfacing failures (and the not-connected case) via `lastActionError`.
    ///
    /// Returns whether the command went out, so an optimistic UI update can be
    /// rolled back when it didn't (see `TransportIntent`). The result is
    /// discardable: most callers still only care about the toast.
    @discardableResult
    func runAction(_ label: String, _ op: (TransportService) async throws -> Void) async -> Bool {
        guard let ts = transportService else {
            lastActionError = ActionError(message: CoreStrings.f(
                "core.error.actionNoConnection", "%@ mislukt — geen verbinding met Roon.", label))
            return false
        }
        do {
            try await op(ts)
            Log.debug("transport-actie '\(label)' verzonden", category: .roon)
            return true
        } catch {
            Log.warning("transport-actie '\(label)' mislukt: \(error)", category: .roon)
            lastActionError = ActionError(message: CoreStrings.f(
                "core.error.actionFailed", "%@ mislukt: %@", label, error.localizedDescription))
            return false
        }
    }

    // MARK: - Optimistic transport

    /// Show a transport change now; let the snapshot confirm or the failure undo it.
    ///
    /// The rollback is conditional on nothing newer having landed: if an
    /// authoritative snapshot arrived while the command was in flight, that is
    /// the truth and this must not overwrite it. Zone is `Equatable`, so
    /// "nothing newer" is simply "the zone still reads exactly as we left it".
    func withOptimistic(_ intent: TransportIntent, zoneID: String,
                        _ send: () async -> Bool) async {
        let before = zones.first(where: { $0.id == zoneID })
        applyOptimistic(intent, zoneID: zoneID)
        let optimistic = zones.first(where: { $0.id == zoneID })
        let ok = await send()
        guard !ok, let before, zones.first(where: { $0.id == zoneID }) == optimistic else { return }
        setZones(replacing(before))
    }

    private func applyOptimistic(_ intent: TransportIntent, zoneID: String) {
        setZones(intent.applied(to: zones, zoneID: zoneID))
    }

    private func replacing(_ zone: Zone) -> [Zone] {
        zones.map { $0.id == zone.id ? zone : $0 }
    }

    /// One place that keeps `zones` and `zoneMap` in step.
    private func setZones(_ new: [Zone]) {
        zones = new
        zoneMap = Dictionary(uniqueKeysWithValues: new.map { ($0.id, $0) })
    }
    public internal(set) var isSyncing = false
    public internal(set) var syncProgress = SyncProgress(phase: "", albumsCompleted: 0, albumsTotal: 0, tracksFound: 0)
    public internal(set) var trackCount = 0
    public internal(set) var isGenreSyncing = false
    public internal(set) var genreCount = 0
    /// Distinct MusicBrainz genres (`track_mb_genres`) — the fine-grained vocabulary
    /// (hundreds of styles) added by analyzer enrichment, far richer than Roon's ~21
    /// broad buckets. Surfaced alongside `genreCount` so the UI reflects the real
    /// genre depth, not just Roon's coarse top-level list.
    public internal(set) var mbGenreCount = 0
    /// Identities of tracks used by recent AI generations (newest last), lightly
    /// de-prioritised so re-running a prompt doesn't return the same playlist.
    /// Lives on the client (not view `@State`) so it survives tab-switches —
    /// exactly when a user re-runs a prompt. Capped to a rolling window.
    public internal(set) var recentlyGeneratedIdentities: [String] = []
    public internal(set) var coreHost: String?
    public internal(set) var corePort: UInt16 = 9330
    public internal(set) var selectedZoneID: String?

    /// Whether we're listening on this device rather than through a Roon zone.
    /// STORED + observable (unlike the old UserDefaults-computed version) so that
    /// SwiftUI re-renders the moment it flips — NowPlayingView branches on it, and
    /// a non-observable value left the screen stuck on the local player after
    /// picking a zone. Persisted to UserDefaults in didSet; restored at init.
    ///
    /// **Defaults to on.** RoonSage is a local music player that can also drive
    /// Roon zones, not a Roon remote that can also play locally — so a fresh
    /// install listens here until the user deliberately picks a zone. `bool(forKey:)`
    /// can't express that (it returns false for "never set"), hence the explicit
    /// object lookup: only a value the user actually chose overrides the default.
    public internal(set) var localOutputSelected: Bool =
        (UserDefaults.standard.object(forKey: "local_output_selected") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(localOutputSelected, forKey: "local_output_selected") }
    }

    /// The active DJ persona (Guest-DJ preset over the smart-radio engine). STORED
    /// + observable so the persona picker re-renders live (same reason as
    /// `localOutputSelected`). Persisted in didSet; restored at init.
    public var selectedDJMode: DJMode = DJMode(rawValue: UserDefaults.standard.string(forKey: "dj_mode") ?? "") ?? .default {
        didSet { UserDefaults.standard.set(selectedDJMode.rawValue, forKey: "dj_mode") }
    }

    /// The persona that steers **any** station you start, or nil for "just use my
    /// adventurousness dial".
    ///
    /// `startRadio(_:zoneID:djMode:)` and `startAlbumRadio(…djMode:)` have always
    /// accepted a persona — a persona is a preset of (dial, arc, gate) over the
    /// same engine, not a separate one. But the UI only ever offered them on the
    /// track playing right now, so "this genre, but adventurous" was a capability
    /// the app had and nobody could reach. Setting this makes every station start
    /// carry it.
    public var stationPersona: DJMode? =
        DJMode(rawValue: UserDefaults.standard.string(forKey: "station_persona") ?? "") {
        didSet {
            UserDefaults.standard.set(stationPersona?.rawValue ?? "", forKey: "station_persona")
        }
    }

    /// When on, normal playback that runs dry is topped up by `selectedDJMode`
    /// seeded on the now-playing track (Plexamp's Guest-DJ autoplay). Off by
    /// default so we never inject tracks the user didn't ask for.
    public var djAutoplayEnabled: Bool = UserDefaults.standard.bool(forKey: "dj_autoplay") {
        didSet { UserDefaults.standard.set(djAutoplayEnabled, forKey: "dj_autoplay") }
    }

    /// When on (with autoplay), the Guest-DJ persona is chosen by time of day
    /// (`DJMode.forTimeOfDay`) instead of the fixed `selectedDJMode` — the station
    /// picks its own mood so you don't have to. STORED + observable so the toggle
    /// re-renders live.
    public var djAutoplayAutoPersona: Bool = UserDefaults.standard.bool(forKey: "dj_autoplay_auto") {
        didSet { UserDefaults.standard.set(djAutoplayAutoPersona, forKey: "dj_autoplay_auto") }
    }

    public var selectedZone: Zone? {
        if let id = selectedZoneID, let z = zoneMap[id] { return z }
        // Never silently fall back to an arbitrary idle zone: doing so once
        // started playback on an unexpected speaker (a Google Home Mini that
        // merely happened to sort first). Only auto-target a zone that is
        // ALREADY playing, and only when exactly one is — so a "play" action can
        // never wake an idle speaker by guessing. Otherwise return nil and let
        // the UI insist on an explicit pick (buttons disable, picker highlights).
        let playing = zones.filter { $0.state == .playing }
        return playing.count == 1 ? playing.first : nil
    }

    // MARK: - Private

    let transport = RoonTransport()
    var zoneMap: [String: Zone] = [:]
    var syncTask: Task<Void, Never>?
    var genreTask: Task<Void, Never>?
    var genreSyncService: LibrarySyncService?
    var lastNowPlaying: [String: String] = [:]  // zoneID → title (dedup guard)
    /// Live per-second playback position from Roon's `zones_seek_changed` frames.
    /// Kept OUT of the observable `zones` array on purpose: re-publishing `zones`
    /// every second would re-invalidate the whole Now Playing UI. Instead the
    /// server overlays this onto each zone when it builds a `/playback` snapshot,
    /// so remote clients get a fresh seek position without any per-second churn.
    @ObservationIgnored var liveSeek: [String: Double] = [:]  // zoneID → seconds

    // Reconnect state
    var intentionalDisconnect = false
    /// Backoff + flap bookkeeping (see `ReconnectPolicy`): the ladder resets on
    /// a connection that HELD, not on every open, so a kick loop backs off
    /// instead of hammering the Core every 2 s.
    var reconnectPolicy = ReconnectPolicy()
    /// When the current websocket opened — feeds the "was it stable?" rule.
    var connectionOpenedAt: Date?
    var reconnectTask: Task<Void, Never>?
    /// Clears the kept-alive zone list when a drop turns out not to be brief.
    var zoneGraceTask: Task<Void, Never>?
    /// True while the zones on screen are the last-known set from a dropped
    /// connection rather than live state.
    public internal(set) var zonesAreStale = false
    /// Set when a fresh zone subscription is issued: the first full `zones`
    /// frame after it replaces the kept list instead of merging into it, so a
    /// zone that disappeared during the outage doesn't linger.
    var expectingFullZoneList = false
    var attemptHost: String?
    var attemptPort: UInt16 = 9330

    // Services — initialised after connection is confirmed
    var transportService: TransportService?
    var browseService: BrowseService?
    public internal(set) var database: DatabaseManager?
    var syncService: LibrarySyncService?
    /// Cached analyzed library for Sonic features (C4) — invalidated on
    /// feature/library sync.
    let sonicCache = SonicLibraryCache()
    /// Station *lists* per category + rotation bucket. Same inputs as
    /// `sonicCache`, so it is invalidated in exactly the same places.
    let radioListCache = RadioListCache()
    /// Gated, serialised listen-logging + LB/Last.fm scrobbling.
    let scrobbler = ScrobbleCoordinator()
    /// Using the app with no server reachable.
    ///
    /// The whole UI used to be gated on a live connection, so in airplane mode
    /// RoonSage was a connect screen and nothing else — even though the library
    /// database, the downloads and the album art all sit on the device. Offline
    /// mode opens the app with what is genuinely local and says what is missing.
    ///
    /// Entered deliberately (the connect screen offers it) or automatically when
    /// a connect attempt fails while a synced library exists. Cleared the moment
    /// a real connection comes back.
    public internal(set) var offlineMode = false

    /// Is there anything to browse without a server? A synced library means yes.
    public var hasLocalLibrary: Bool { trackCount > 0 }

    public func enterOfflineMode() {
        guard hasLocalLibrary else { return }
        offlineMode = true
        // Anything queued locally keeps playing; downloads and the cache answer
        // without the network. Nothing to tear down.
        Log.info("Offlinemodus aan — \(trackCount) tracks lokaal beschikbaar", category: .app)
    }

    public func leaveOfflineMode() { offlineMode = false }

    /// Live progress of a running offline download, or nil when idle.
    public internal(set) var downloadProgress: DownloadProgress?
    /// Match keys that are pinned to this device — read per row to show a mark,
    /// so the UI never stats the filesystem in a list.
    public internal(set) var offlineKeys: Set<String> = []
    /// One-shot guard for `startOfflineDownloads()` — the engine's callbacks are
    /// wired once per process, not once per download.
    @ObservationIgnored var offlineDownloadsStarted = false

    /// Watches for system memory pressure so the sonic caches can be dropped.
    /// See `startMemoryPressureRelief()`.
    @ObservationIgnored var memoryPressureSource: (any DispatchSourceMemoryPressure)?
    /// HTTP server other devices import the library from (Settings toggle).
    var shareServer: LibraryShareServer?
    /// Cached signature of the analyzer's feature/embedding state (set by the
    /// analyzer app when it starts serving). Folded into `libraryRevision` so
    /// remotes auto-re-pull when analyses change — WITHOUT a per-poll DB read.
    public var featuresRevision: String = ""

    // MARK: - ListenBrainz playlist sync (server only)

    /// Whether the daily ListenBrainz → playlist-library import is on. Mirrored to
    /// UserDefaults so it survives launches; observable so Settings stays in sync.
    public internal(set) var lbPlaylistSyncEnabled: Bool =
        UserDefaults.standard.bool(forKey: "listenbrainz_playlist_sync_enabled")
    /// Human-readable status of the last import, shown in Settings.
    public internal(set) var lbPlaylistSyncStatus: String = ""
    /// Whether imported ListenBrainz playlists are also mirrored to Qobuz (as
    /// "ListenBrainz · <name>" playlists) on each daily import. Requires Qobuz
    /// credentials. Mirrored to UserDefaults; observable for Settings.
    public internal(set) var lbQobuzSyncEnabled: Bool =
        UserDefaults.standard.bool(forKey: "listenbrainz_qobuz_sync_enabled")
    #if os(macOS)
    /// The running daily-import loop (nil when disabled).
    var lbPlaylistSyncTask: Task<Void, Never>?
    #endif

    // MARK: - Last.fm playlist sync (server only)

    /// Whether the daily Last.fm top-tracks → playlist-library import is on.
    public internal(set) var lastfmPlaylistSyncEnabled: Bool =
        UserDefaults.standard.bool(forKey: "lastfm_playlist_sync_enabled")
    /// Whether the Last.fm-derived playlists are also mirrored to Qobuz.
    public internal(set) var lastfmQobuzSyncEnabled: Bool =
        UserDefaults.standard.bool(forKey: "lastfm_qobuz_sync_enabled")
    /// Human-readable status of the last Last.fm playlist import, shown in Settings.
    public internal(set) var lastfmPlaylistSyncStatus: String = ""
    #if os(macOS)
    var lastfmPlaylistSyncTask: Task<Void, Never>?
    // The analyzer server's Roon-connect loop. Started from init() (not a SwiftUI
    // `.task`) so it runs even when the headless mini's Window scene never
    // activates — see startServerBackgroundWork(). The Last.fm-scrobble loop that
    // sat beside it is now a TaskScheduler job.
    var serverRoonConnectTask: Task<Void, Never>?
    #endif

    public init() {
        database = DatabaseManager.open(url: Self.databaseURL)
        // Restore the last explicitly-chosen zone so a play action targets the
        // same speaker across launches instead of resetting to "no selection"
        // (which previously routed to an arbitrary first zone). Resolves to nil
        // automatically if that zone is gone — `selectedZone` checks `zoneMap`.
        selectedZoneID = UserDefaults.standard.string(forKey: "selected_zone_id")
        refreshTrackCount()
        refreshGenreCount()
        // On-device plays scrobble and land in listening_history like zone plays.
        startLocalScrobbleBridge()
        // Give the ~113 MB sonic vector index back when the system asks for it.
        startMemoryPressureRelief()
        Task { await refreshOfflineKeys() }
        // Reattach the background download session: a queue that finished while
        // the app was suspended has results waiting, and without this they are
        // never written to the bookkeeping table.
        startOfflineDownloads()
        #if os(macOS)
        // Sharing defaults to on so the iPhone can pull library + settings
        // without the user flipping a toggle first; an explicit opt-out (key
        // set to false) is still honoured. Gated to macOS — RoonClient.shared
        // also exists on iOS, which must not start a share server.
        let shareEnabled = UserDefaults.standard.object(forKey: "library_share_enabled") as? Bool ?? true
        if shareEnabled {
            setLibrarySharing(enabled: true)
        }
        // Resume the daily ListenBrainz playlist import if the user enabled it.
        if lbPlaylistSyncEnabled {
            startListenBrainzPlaylistSync()
        }
        // Resume the daily Last.fm top-tracks playlist import if enabled.
        if lastfmPlaylistSyncEnabled {
            startLastfmPlaylistSync()
        }
        // The analyzer SERVER must stay connected to Roon and keep pulling Last.fm
        // scrobbles. These start from init — NOT a SwiftUI `.task` — because the
        // headless server's Window scene never activates when the mini's display
        // is asleep, so its `.task` modifiers silently never fire (which left the
        // server serving a stale library while never pairing with Roon). Gated to
        // the analyzer via its distinct extension identity so the thin Mac client
        // (which talks to the share server, not Roon) never triggers it.
        if RoonClientAuth.extensionIDOverride == "com.roonsage.server" {
            startServerBackgroundWork()
        }
        // One-time forced Qobuz resync: set via `defaults write <bundle-id>
        // qobuz_force_resync_once -bool YES` before a restart. Corrects playlists
        // whose Qobuz copy bloated from the (now-fixed) incomplete-clear bug in
        // QobuzClient.deletePlaylistTracks by bypassing the shrink guard exactly
        // once. Self-clears immediately so a later ordinary restart never re-runs
        // it automatically.
        if UserDefaults.standard.bool(forKey: "qobuz_force_resync_once") {
            UserDefaults.standard.set(false, forKey: "qobuz_force_resync_once")
            Task { [weak self] in
                // Long delay so this never overlaps the routine startup syncs
                // (LB/Last.fm ~15-20s, AI radios ~20s) — running concurrently with
                // them caused a ListenBrainz API race that silently emptied one
                // of the two fetches (its "transient outage, keep existing" guard
                // fired instead of erroring), skipping the forced Qobuz mirror.
                try? await Task.sleep(nanoseconds: 150_000_000_000)
                guard let self else { return }
                Log.notice("Eenmalige geforceerde Qobuz-resync gestart (bloat-fix)", category: .network)
                if self.lbQobuzSyncEnabled { await self.runListenBrainzPlaylistSync(forceReplace: true) }
                if self.lastfmQobuzSyncEnabled { await self.runLastfmPlaylistSync(forceReplace: true) }
                for cat in RadioCategory.allCases {
                    await self.syncRadiosToQobuz(category: cat, forceReplace: true)
                }
                Log.notice("Eenmalige geforceerde Qobuz-resync klaar", category: .network)
            }
        }
        #endif
    }

    #if os(macOS)
    /// Kick off ALL the analyzer server's long-running background work in retained
    /// Tasks (idempotent). Called from init on the server so it survives regardless
    /// of the SwiftUI Window scene's lifecycle — a `.task` on the headless server's
    /// Window never fires when the mini's display is asleep. (The AnalyzerModel-side
    /// jobs — analysis, CLAP, the :5766 serve — are started from the analyzer app's
    /// init for the same reason; those need the model, which lives there.)
    func startServerBackgroundWork() {
        if serverRoonConnectTask == nil {
            serverRoonConnectTask = Task { [weak self] in await self?.serverRoonConnectLoop() }
        }
        // Every fixed-cadence job below runs under TaskScheduler, so a restart
        // resumes each cadence from its persisted `last_execution` instead of
        // re-running every startup grace, and /system/tasks can report on it.
        // `serverRoonConnectLoop` above stays hand-written on purpose: its waits
        // depend on connection state (3/5/6 s) and it carries local retry counters.
        if let database {
            Task { await TaskScheduler.shared.attach(database: database) }
        }
        Task { [weak self] in
            await TaskScheduler.shared.register(
                name: "lastfm-scrobble-sync",
                title: "Last.fm-scrobbles ophalen",
                interval: 15 * 60
            ) { [weak self] in
                guard let self else { return .skipped }
                await self.syncRecentLastfmScrobbles()
                return .completed
            }
        }
        // The server's periodic Qobuz / discovery / lyrics / feature schedules
        // (each guards against double-start internally).
        startArtistRadioRefresh()
        startDiscoveryRefresh()
        startDigestSchedule()
        startDiscoverWeeklySchedule()
        startServerFeatureSync()
        startLyricsBackfill()
        startRecapGeneration()
        startMaintenance()
    }

    /// The server must stay connected to Roon. Keep (re)trying from a not-
    /// connected state: saved host → SOOD discovery → localhost (the server
    /// usually runs on the Core machine). A handshake that drops before
    /// authorization leaves us `.disconnected` without auto-reconnect, so we
    /// drive the retry here.
    ///
    /// - `.connecting` is bounded: the transport self-aborts a stalled handshake
    ///   (~18s), but as a final backstop we force a teardown if it lingers.
    /// - After repeated saved-host failures we fall through to SOOD discovery, so
    ///   a Core that moved to a new IP is rediscovered automatically.
    private func serverRoonConnectLoop() async {
        var savedHostFailures = 0
        var connectingSince: Date?
        while !Task.isCancelled {
            switch connectionState {
            case .connected, .awaitingAuthorization, .discovering:
                savedHostFailures = 0
                connectingSince = nil
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                continue
            case .connecting:
                let now = Date()
                let since = connectingSince ?? now
                connectingSince = since
                if now.timeIntervalSince(since) > 25 {
                    await disconnect()   // break a stuck handshake
                    connectingSince = nil
                } else {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
                continue
            default:
                connectingSince = nil   // .disconnected / .failed → (re)try
            }
            if let host = savedHost, savedHostFailures < 3 {
                savedHostFailures += 1
                await connect(host: host, port: savedPort)
            } else {
                await discoverAndConnect()
                if case .failed = connectionState {
                    await connect(host: "127.0.0.1", port: 9330)
                }
                savedHostFailures = 0
            }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
        }
    }
    #endif

    /// Start/stop the library-share HTTP server (persisted; auto-starts at
    /// launch when enabled). Other devices import via GET /library on port 5767.
    public func setLibrarySharing(enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: "library_share_enabled")
        if enabled {
            guard shareServer == nil, let db = database else { return }
            let server = LibraryShareServer(database: db)
            try? server.start()
            shareServer = server
        } else {
            shareServer?.stop()
            shareServer = nil
        }
    }

    public var isLibrarySharing: Bool { shareServer != nil }

    /// Turn the daily ListenBrainz playlist import on/off (persisted). Enabling
    /// runs an import immediately; disabling stops the loop. No-op off the server.
    public func setListenBrainzPlaylistSync(enabled: Bool) {
        lbPlaylistSyncEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "listenbrainz_playlist_sync_enabled")
        #if os(macOS)
        if enabled {
            startListenBrainzPlaylistSync(initialDelay: 0)
        } else {
            stopListenBrainzPlaylistSync()
            lbPlaylistSyncStatus = ""
        }
        #endif
    }

    /// Trigger a one-off ListenBrainz playlist import now (Settings "sync now").
    public func syncListenBrainzPlaylistsNow() {
        #if os(macOS)
        Task { await runListenBrainzPlaylistSync() }
        #endif
    }

    /// Turn mirroring of imported ListenBrainz playlists to Qobuz on/off
    /// (persisted). When enabled, the next import (and "sync now") also pushes
    /// them to Qobuz. No-op off the server.
    public func setListenBrainzQobuzSync(enabled: Bool) {
        lbQobuzSyncEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "listenbrainz_qobuz_sync_enabled")
    }

    /// Turn the daily Last.fm top-tracks → playlist import on/off (persisted).
    /// Enabling runs an import immediately. No-op off the server.
    public func setLastfmPlaylistSync(enabled: Bool) {
        lastfmPlaylistSyncEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "lastfm_playlist_sync_enabled")
        #if os(macOS)
        if enabled {
            startLastfmPlaylistSync(initialDelay: 0)
        } else {
            stopLastfmPlaylistSync()
            lastfmPlaylistSyncStatus = ""
        }
        #endif
    }

    /// Turn mirroring of Last.fm-derived playlists to Qobuz on/off (persisted).
    public func setLastfmQobuzSync(enabled: Bool) {
        lastfmQobuzSyncEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "lastfm_qobuz_sync_enabled")
    }

    /// Trigger a one-off Last.fm playlist import now (Settings "sync now").
    public func syncLastfmPlaylistsNow() {
        #if os(macOS)
        Task { await runLastfmPlaylistSync() }
        #endif
    }

    // MARK: - Database URL

    /// Database filename. Defaults to `library.db` (used by the server build and
    /// the MCP tool). Client apps set this to a separate file via
    /// `useServerMode()` so a client running on the *same machine* as the server
    /// can't clobber the server's authoritative DB (they share the same
    /// Application Support/RoonSage directory — the path isn't bundle-scoped).
    public static var databaseFileOverride: String?

    static var databaseURL: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = appSupport.appendingPathComponent("RoonSage", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(databaseFileOverride ?? "library.db")
    }

    // MARK: - Connection

    /// Reduce free-form user/saved input to a bare host. People paste
    /// `http://10.0.0.5`, `https://host/`, or `host:5767`; in server mode we then
    /// build `http://<host>:5767` ourselves, so a leftover scheme/port/path would
    /// produce a broken URL (`http://http://…`) and silently fail to connect.
    public nonisolated static func normalizeHost(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }   // drop scheme
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }   // drop path
        // Drop a trailing :port (but never inside an IPv6 literal like [::1]).
        if !s.contains("["), let colon = s.lastIndex(of: ":") { s = String(s[..<colon]) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func connect(host rawHost: String, port: UInt16 = 9330) async {
        // Server mode: no Roon socket. Treat the host (saved/typed) as the
        // RoonSage server address on the share port; empty host → auto-discover.
        if isRemote {
            let h = Self.normalizeHost(rawHost)
            if !h.isEmpty { remoteBaseURL = "http://\(h):\(LibraryShareServer.defaultPort)" }
            await startServerMode(); return
        }
        // Text-field input often carries stray whitespace from copy/paste — a
        // space inside the authority makes URL(string:) return nil, which used
        // to crash the transport's force-unwrap. Sanitise and validate first.
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty, URL(string: "ws://\(host):\(port)/api") != nil else {
            connectionState = .failed("Ongeldige host of poort: \(rawHost.debugDescription)")
            return
        }
        intentionalDisconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        attemptHost = host
        attemptPort = port
        coreHost = host
        corePort = port
        connectionState = .connecting(host: host)
        Log.info("connect → ws://\(host):\(port)/api", category: .roon)
        await transport.configure(
            onOpen: { [weak self] in await self?.handleOpen(host: host) },
            onClose: { [weak self] in await self?.handleClose() }
        )
        await transport.connect(host: host, port: port)
    }

    /// For background actions (App Intents): make sure we're connected to the
    /// saved Core, waiting briefly for the handshake. Returns whether a
    /// connection (and thus a controllable zone list) is available.
    public func ensureConnected(timeout: TimeInterval = 6) async -> Bool {
        if connectionState.isConnected { return true }
        if isRemote { await startServerMode() }
        else {
            guard let host = savedHost else { return false }
            await connect(host: host, port: savedPort)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if connectionState.isConnected, !zones.isEmpty { return true }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return connectionState.isConnected
    }

    /// Foreground fast-path. iOS tears down the websocket on suspension;
    /// `handleClose` then schedules a reconnect with exponential backoff (up to
    /// 30 s). When the user reopens the app we don't want to sit out that
    /// backoff — cancel it and reconnect now, so a play tap right after
    /// foregrounding isn't a silent no-op against a dead socket. No-op when
    /// already connected/connecting or the user disconnected on purpose.
    public func reconnectOnForeground() {
        if isRemote { Task { await startServerMode(forceReconnectStream: true) }; return }
        guard !intentionalDisconnect, let host = savedHost else { return }
        switch connectionState {
        case .disconnected, .failed:
            reconnectPolicy.reset()
            Task { await connect(host: host, port: savedPort) }
        default:
            break   // connected / connecting / discovering / awaitingAuthorization
        }
    }

    public func discoverAndConnect() async {
        // Explicit "find server" in client mode: drop the remembered address so
        // we do a fresh Bonjour browse rather than re-trying a stale IP.
        if isRemote { remoteBaseURL = nil; await startServerMode(); return }
        connectionState = .discovering
        let preferredID = RoonClientAuth.loadCoreID()
        let cores = await SoodDiscovery.discover(coreID: preferredID)
        guard let first = cores.first else {
            connectionState = .failed("Geen Roon Core gevonden op het lokale netwerk.\nControleer of Roon draait.")
            return
        }
        await connect(host: first.host, port: first.httpPort)
    }

    public func disconnect() async {
        intentionalDisconnect = true
        hasLiveSession = false
        reconnectTask?.cancel()
        reconnectTask = nil
        syncTask?.cancel()
        // In server mode the poll loop would otherwise revive the connection on
        // its next tick — stop it so a deliberate disconnect actually sticks.
        if isRemote { stopServerMode(); remoteBaseURL = nil }
        await transport.disconnect()
        transportService = nil
        browseService = nil
        syncService = nil
        connectionState = .disconnected
        reconnectPolicy.reset()
        clearZones()
    }

    public func clearAndReauthorize() async {
        intentionalDisconnect = true
        hasLiveSession = false
        reconnectTask?.cancel()
        reconnectTask = nil
        RoonClientAuth.clearCredentials()
        await disconnect()
    }

    // MARK: - Private connection flow

    // MARK: - Saved host (persisted across launches)

    public var savedHost: String? { UserDefaults.standard.string(forKey: "lastRoonHost") }
    public var savedPort: UInt16 {
        let p = UserDefaults.standard.integer(forKey: "lastRoonPort")
        return p > 0 ? UInt16(p) : 9330
    }
    func persistHost(_ host: String, port: UInt16) {
        UserDefaults.standard.set(Self.normalizeHost(host), forKey: "lastRoonHost")
        UserDefaults.standard.set(Int(port), forKey: "lastRoonPort")
    }

    func handleOpen(host: String) async {
        // Deliberately NOT resetting the backoff here: an open that gets kicked
        // two seconds later is not proof of a healthy link. `ReconnectPolicy`
        // resets once the connection has actually held (see its doc comment).
        connectionOpenedAt = Date()
        let ts = TransportService(transport: transport)
        let bs = BrowseService(transport: transport)
        transportService = ts
        browseService = bs

        // Load the token OFF the MainActor: KeychainStore.load is a synchronous
        // SecItemCopyMatching that can block (e.g. an access prompt under a
        // changed code signature), which would freeze the MainActor — and with
        // it the share server's /playback. Keep the main thread free.
        let token = await Task.detached { RoonClientAuth.loadToken() }.value
        let payload = RoonClientAuth.registerPayload(existingToken: token)
        let extID = (payload["extension_id"] as? String) ?? "?"
        Log.info("ws open op \(host); registreren als \(extID) (token: \(token == nil ? "geen" : "aanwezig"))", category: .roon)

        if token == nil { connectionState = .awaitingAuthorization }

        do {
            // With a saved token Roon answers promptly (Registered/Unauthorized);
            // bound the wait so a silent Core (seen after a token glitch) can't
            // park us in `.connecting` forever. First-time auth (token == nil)
            // gets NO timeout — it waits for the user to enable the extension.
            let body = try await transport.register(
                payload: payload,
                timeoutNanos: token == nil ? nil : 20_000_000_000
            )
            guard let reg = RoonClientAuth.parseRegistration(body) else {
                // Log only the keys — the raw body carries the Roon token, and
                // the log file is meant to be shareable.
                Log.error("registratie-antwoord onbruikbaar; velden: \(body.keys.sorted())", category: .roon)
                connectionState = .failed("Onverwacht registratie-antwoord")
                return
            }
            Log.info("geregistreerd bij \(reg.coreName) (core \(reg.coreID))", category: .roon)
            let previousCoreID = RoonClientAuth.loadCoreID()
            RoonClientAuth.saveToken(reg.token, coreID: reg.coreID)
            persistHost(host, port: corePort)
            // Re-assert the host alongside the connected state. `connect()` sets it
            // up front, but a close belonging to an EARLIER socket can land while
            // this registration is still in flight — `handleClose` nils it
            // unconditionally, and we would then be `.connected` with no host. That
            // leaves `imageURL` returning nil, i.e. no album art anywhere on every
            // client, which is exactly how it surfaced on 2026-08-08.
            coreHost = host
            connectionState = .connected(coreName: reg.coreName)
            await subscribeZones()
            // A different Core (reinstall / another machine) means the cached
            // library — including every item_key — belongs to a foreign session
            // and won't resolve, so resync from scratch. A *same*-Core restart
            // keeps the cache; stale keys there are handled at play time by the
            // search fallback in BrowseService.playByBrowse (cheaper than a full
            // re-walk on every reconnect).
            let coreChanged = previousCoreID != nil && previousCoreID != reg.coreID
            // Hoisted out of the `||` — its right operand is a non-async autoclosure.
            let hasNullKeys = (try? await database?.hasNullMatchKeys()) == true
            let needsResync = trackCount == 0 || coreChanged || hasNullKeys
            if needsResync { startSync() }
        } catch {
            Log.error("registratie mislukt: \(error.localizedDescription)", category: .roon)
            // The socket opened but registration didn't complete (timeout/refused).
            // Close it so the next attempt starts on a fresh socket instead of
            // leaving this one dangling open (a retry would otherwise leak it).
            await transport.disconnect()
            connectionState = .failed(error.localizedDescription)
        }
    }

    func handleClose() async {
        // Reconnect after any established or authorization-pending connection drop.
        // "awaitingAuthorization" drops can happen over flaky networks (ZeroTier etc.)
        // before the user has a chance to approve; retry so Roon re-shows the prompt.
        let shouldReconnect: Bool
        switch connectionState {
        case .connected:             shouldReconnect = true
        case .awaitingAuthorization: shouldReconnect = true
        default:                     shouldReconnect = false
        }
        let host = attemptHost
        let port = attemptPort
        Log.info("ws gesloten (state \(connectionState.label)); reconnect=\(shouldReconnect)", category: .roon)

        transportService = nil
        browseService = nil
        coreHost = nil
        connectionState = .disconnected

        let outcome = reconnectPolicy.connectionClosed(openedAt: connectionOpenedAt)
        connectionOpenedAt = nil
        if outcome.isFlapping {
            // Naming the usual suspect here saves an evening of log reading: a
            // Roon Core keeps ONE connection per extension id, so a second copy
            // of this app (login item + LaunchAgent both starting it) makes the
            // two kick each other forever. That is exactly how 2026-08-22 looked.
            Log.warning("""
                Roon-verbinding flappert: \(outcome.closesInWindow) sluitingen in \
                \(Int(ReconnectPolicy.flapWindow))s. Draait er een tweede RoonSage-server? \
                De Core laat maar één verbinding per extensie toe en schopt de oudste eruit.
                """, category: .roon)
        }

        guard !intentionalDisconnect, shouldReconnect, let host else {
            // Not coming back — drop the zones now rather than showing a list
            // that will never refresh.
            clearZones()
            return
        }

        // KEEP the last-known zones for a grace window instead of clearing them
        // here. Every close used to blank `zones`, and since the server hands
        // that same list to every client, a two-second blip made the chosen zone
        // vanish app-wide (buttons disabled, Now Playing empty, the zone picker
        // back to "kies een zone"). The snapshot still reports roonConnected =
        // false, so nothing pretends the link is up.
        zonesAreStale = !zones.isEmpty
        startZoneGrace()

        reconnectTask?.cancel()
        reconnectTask = Task {
            try? await Task.sleep(nanoseconds: outcome.delaySeconds * 1_000_000_000)
            guard !Task.isCancelled, !self.intentionalDisconnect else { return }
            await self.connect(host: host, port: port)
        }
    }

    /// How long a dropped connection may keep showing its last-known zones.
    /// Longer than the first few backoff steps (2 + 4 + 8 s) so an ordinary
    /// reconnect never blanks the UI, short enough that a Core that stays away
    /// stops pretending.
    static let zoneGraceSeconds: UInt64 = 45

    private func startZoneGrace() {
        guard !zones.isEmpty else { return }
        zoneGraceTask?.cancel()
        zoneGraceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.zoneGraceSeconds * 1_000_000_000)
            guard !Task.isCancelled, let self, !self.connectionState.isConnected else { return }
            self.clearZones()
        }
    }

    func clearZones() {
        zoneGraceTask?.cancel()
        zoneGraceTask = nil
        zonesAreStale = false
        zones = []
        zoneMap = [:]
    }

    func subscribeZones() async {
        // A failed zone subscription used to silently give up, leaving Now
        // Playing permanently empty until a full reconnect. Two failure
        // modes, two guards: a throwing send retries after 3s; a subscribe
        // whose initial state never arrives (dropped COMPLETE on a flaky
        // link) is detected by a 10s watchdog that re-issues the
        // subscription. A re-issue uses a fresh subscription_key; should the
        // old stream come alive after all, applyZoneUpdate is idempotent.
        // The next full `zones` frame belongs to a FRESH subscription: it must
        // replace whatever we kept during the grace window (see handleClose),
        // otherwise a zone that disappeared while we were away lingers forever
        // because applyZoneUpdate only ever merges.
        expectingFullZoneList = true
        guard let stream = try? await transport.subscribe(
            service: RoonService.transport,
            endpoint: "zones"
        ) else {
            Task {
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                guard connectionState.isConnected else { return }
                await subscribeZones()
            }
            return
        }

        zonesWatchdog?.cancel()
        zonesWatchdog = Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard !Task.isCancelled, connectionState.isConnected, zoneMap.isEmpty else { return }
            await subscribeZones()
        }

        Task {
            for await body in stream {
                zonesWatchdog?.cancel()
                await self.applyZoneUpdate(body)
            }
        }
    }

    // MARK: - Play queue

    /// Whether this process owns the queue subscription, or is fed one.
    ///
    /// In `.server` mode there is no Roon WebSocket to subscribe to: `queueItems`
    /// arrives with every `PlaybackSnapshot` (`applyPlaybackSnapshot`). Starting
    /// or stopping a subscription there is not merely useless, it is destructive
    /// — both ends clear `queueItems`, and the snapshot that refills it only
    /// arrives when the state CHANGES (`PlaybackEventHub` pushes on a digest
    /// change) or when the 15 s fallback poll fires. Opening the queue on a
    /// paused zone therefore showed "niets in de wachtrij" for up to 15 seconds,
    /// and leaving it blanked the player's up-next pill for the same window.
    nonisolated static func ownsQueueSubscription(mode: RoonControlMode) -> Bool {
        mode == .direct
    }

    var ownsQueueSubscription: Bool { Self.ownsQueueSubscription(mode: controlMode) }

    /// Subscribe to a zone's play queue. Maintains `queueItems` (initial list +
    /// incremental insert/remove changes from Roon). No-op in `.server` mode —
    /// see `ownsQueueSubscription`.
    public func startQueue(zoneID: String) {
        guard ownsQueueSubscription else { return }
        queueTask?.cancel()
        queueItems = []
        queueZoneID = zoneID
        queueTask = Task {
            guard let stream = try? await transport.subscribe(
                service: RoonService.transport, endpoint: "queue",
                params: ["zone_or_output_id": zoneID, "max_item_count": 200]
            ) else { return }
            for await body in stream {
                applyQueue(body)
            }
        }
    }

    public func stopQueue() {
        guard ownsQueueSubscription else { return }
        queueTask?.cancel()
        queueTask = nil
        queueItems = []
    }

    public func playFromHere(zoneID: String, queueItemID: Int) async {
        if isRemote { var c = RemoteCommand("playFromHere"); c.zoneID = zoneID; c.queueItemID = queueItemID; await remote(c); return }
        try? await transportService?.playFromHere(zoneID: zoneID, queueItemID: queueItemID)
    }

    func applyQueue(_ body: [String: Any]) {
        if let items = body["items"] as? [[String: Any]] {
            queueItems = items.compactMap(Self.parseQueueItem)
        } else if let changes = body["changes"] as? [[String: Any]] {
            var current = queueItems
            for change in changes {
                let op = change["operation"] as? String
                // A missing index used to default to 0, which would remove or
                // insert at the head of the queue — corrupting the view on a
                // malformed change. Skip changes Roon didn't position.
                guard let index = change["index"] as? Int else { continue }
                if op == "remove" {
                    let count = change["count"] as? Int ?? 0
                    if index < current.count {
                        current.removeSubrange(index..<min(index + count, current.count))
                    }
                } else if op == "insert", let its = change["items"] as? [[String: Any]] {
                    current.insert(contentsOf: its.compactMap(Self.parseQueueItem), at: min(index, current.count))
                }
            }
            queueItems = current
        }
    }

    static func parseQueueItem(_ d: [String: Any]) -> QueueItem? {
        guard let id = d["queue_item_id"] as? Int else { return nil }
        let two = d["two_line"] as? [String: Any]
        let three = d["three_line"] as? [String: Any]
        let title = (three?["line1"] as? String) ?? (two?["line1"] as? String) ?? "Unknown"
        let subtitle = (two?["line2"] as? String) ?? (three?["line2"] as? String)
        return QueueItem(id: id, title: title, subtitle: subtitle,
                         length: d["length"] as? Int ?? 0, imageKey: d["image_key"] as? String)
    }

    func applyZoneUpdate(_ body: [String: Any]) async {
        let toUpdate = (body["zones_changed"] as? [[String: Any]])
            ?? (body["zones_added"]   as? [[String: Any]])
            ?? (body["zones"]         as? [[String: Any]]) ?? []
        let toRemove = body["zones_removed"] as? [String] ?? []

        // Roon emits `zones_seek_changed` roughly once per second per playing
        // zone. We don't rebuild the observable `zones` array for these (that
        // would re-invalidate the whole Now Playing UI every tick), but we DO
        // record the fresh position in `liveSeek` so `/playback` snapshots stay
        // accurate for remote clients (whose own poll is too coarse to track it).
        if let seeks = body["zones_seek_changed"] as? [[String: Any]] {
            for s in seeks {
                guard let zid = s["zone_id"] as? String else { continue }
                if let pos = s["seek_position"] as? Double { liveSeek[zid] = pos }
                else if let pos = s["seek_position"] as? Int { liveSeek[zid] = Double(pos) }
            }
        }

        // A seek-only frame carries no structural change — returning early avoids
        // reassigning the observable `zones` array on every tick.
        if toUpdate.isEmpty && toRemove.isEmpty { return }

        // First full list after a (re)subscribe: drop anything Roon no longer
        // reports, so the grace-window list can't outlive the zone itself.
        if expectingFullZoneList, let full = body["zones"] as? [[String: Any]] {
            expectingFullZoneList = false
            let live = Set(full.compactMap { $0["zone_id"] as? String })
            for gone in zoneMap.keys where !live.contains(gone) {
                zoneMap.removeValue(forKey: gone)
                liveSeek.removeValue(forKey: gone)
                lastNowPlaying.removeValue(forKey: gone)
            }
        }
        zoneGraceTask?.cancel()
        zoneGraceTask = nil
        zonesAreStale = false

        for dict in toUpdate {
            let zone = Zone(from: dict)

            // Log a listen + scrobble when now-playing changes on a playing
            // zone. All IO (Keychain, SQLite, network) runs in the
            // ScrobbleCoordinator actor, which also applies the minimum-play
            // gate — only the dedup guard stays on the MainActor.
            if zone.state == .playing, let np = zone.nowPlaying {
                let key = zone.id
                if lastNowPlaying[key] != np.title {
                    lastNowPlaying[key] = np.title
                    let item = ScrobbleCoordinator.Item(
                        title: np.title, artist: np.artist, album: np.album,
                        length: np.length.map(Double.init),
                        zoneID: zone.id, zoneName: zone.displayName)
                    let db = database
                    Task { await scrobbler.trackChanged(item, database: db) }
                }
            }

            zoneMap[zone.id] = zone
            // Re-sync the live seek to this structural position (track change /
            // play-pause), so a snapshot doesn't briefly overlay the previous
            // track's position before the next per-second frame arrives.
            liveSeek[zone.id] = zone.seekPosition ?? 0
            maybeAutoplayGuestDJ(for: zone)
        }
        for id in toRemove {
            lastNowPlaying.removeValue(forKey: id)
            zoneMap.removeValue(forKey: id)
            liveSeek.removeValue(forKey: id)
            Task { await scrobbler.zoneRemoved(id) }
        }
        zones = Array(zoneMap.values).sorted { $0.displayName < $1.displayName }
    }

    func refreshTrackCount() {
        guard let db = database else { trackCount = 0; return }
        // Fire-and-forget so init / import paths never block main on SQLite.
        Task { [weak self] in
            let count = (try? await db.trackCount()) ?? 0
            self?.trackCount = count
        }
    }

    func refreshGenreCount() {
        guard let db = database else { genreCount = 0; mbGenreCount = 0; return }
        Task { [weak self] in
            let counts = (try? await db.genreCounts()) ?? (roon: 0, musicbrainz: 0)
            self?.genreCount = counts.roon
            self?.mbGenreCount = counts.musicbrainz
        }
    }
}

