import SwiftUI
import RoonSageCore

/// Where this Settings screen runs.
/// - `.server`: the always-on analyzer/server app — everything editable; this is
///   the single place to configure LLM, Last.fm, Qobuz, analyzer, etc.
/// - `.client`: the Mac/iOS remote apps — almost everything is gone. They only
///   pick a server address, pull config + library + features from it, and keep
///   the per-device Roon authorization + local appearance.
public enum SettingsRole: Sendable {
    case server
    case client
}

/// Which half of the settings a page shows.
///
/// The old screen was one `Form` of 21 sections gated by `role`, and that gate
/// was the wrong axis: on 2026-08-11 four sections about how audio sounds on
/// THIS device (loudness, the cellular transcode, the audio cache, offline
/// downloads) sat inside `if role == .server` and were therefore invisible on
/// the phone — the only device they exist for (v1.10.257). The distinction that
/// matters isn't "server or client" but **"does this configure the server, or
/// how it sounds here"**, and those two run straight through each other in that
/// list. Making it a scope rather than a role puts the answer in the type.
public enum SettingsScope: Sendable {
    /// How the app looks and sounds on this device.
    case device
    /// Roon, the library, the analyzer and the external accounts.
    case server
    /// Both, in one page. macOS keeps this; the phone splits.
    case all
}

extension View {
    /// Shows this section only when it belongs to the page being rendered.
    ///
    /// A modifier rather than an `if` around each block on purpose: wrapping 500
    /// lines in a conditional would have re-indented most of the file and buried
    /// the actual change in whitespace.
    @ViewBuilder
    func scoped(_ section: SettingsScope, in page: SettingsScope) -> some View {
        if page == .all || page == section { self }
    }
}

@MainActor
public struct SettingsView: View {
    private let role: SettingsRole
    private let scope: SettingsScope
    @Environment(RoonClient.self) private var client
    @Environment(\.openURL) private var openURL
    @AppStorage("themePreset") private var themePreset: ThemePreset = .custom
    @AppStorage("themeMode") private var themeMode: ThemeMode = .system
    @AppStorage("accentChoice") private var accent: AccentChoice = .gold
    @AppStorage("ambientIntensity") private var ambientIntensity: Double = 1.0
    @AppStorage("ambientWallpaper") private var ambientWallpaper: Bool = false
    @AppStorage("appLanguage") private var appLanguage: LocalePreference = .system
    @AppStorage("showVisualizer") private var showVisualizer = true
    @State private var lastSync: String = "—"

    // Server sync (client role: pull settings + library + features from the server)
    @State private var serverURL: String = UserDefaults.standard.string(forKey: "library_import_url") ?? ""
    @State private var serverToken: String = LibraryShareServer.configuredToken ?? ""
    @State private var savedServerToken: String = LibraryShareServer.configuredToken ?? ""
    @State private var tokenSaved = false
    @State private var settingsSyncBusy = false
    @State private var settingsSyncStatus: String?

    public init(role: SettingsRole = .client, scope: SettingsScope = .all) {
        self.role = role
        self.scope = scope
    }

    /// "21 + 452 via MusicBrainz" — the coarse Roon buckets plus the fine-grained MB
    /// vocabulary, so the depth added by analyzer enrichment is visible rather than
    /// hidden behind Roon's ~21 top-level genres.
    private var genreCountLabel: String {
        if client.genreCount == 0 && client.mbGenreCount == 0 { return "Niet gesynchroniseerd" }
        if client.mbGenreCount > 0 {
            return "\(client.genreCount) + \(client.mbGenreCount) via MusicBrainz"
        }
        return "\(client.genreCount)"
    }

    // ListenBrainz
    @State private var lbToken: String = ""
    @State private var lbSaved = false
    @State private var lbLovesBusy = false
    @State private var lbLovesResult = ""

    // Discogs (F7 — Discogs Labels discovery producer)
    @State private var discogsToken: String = ""
    @State private var discogsSaved = false

    // Last.fm
    @State private var lfApiKey: String = ""
    @State private var lfApiSecret: String = ""
    @State private var lfUsername: String = ""
    @State private var lfConnected = false
    @State private var lfPendingToken: String? = nil
    @State private var lfBusy = false
    @State private var lfStatus: String = ""
    @AppStorage("lastfm_scrobble_enabled") private var lfScrobbleFromApp = false

    // Qobuz
    @State private var qbEmail: String = ""
    @State private var qbPassword: String = ""
    @State private var qbBusy = false
    @State private var qbStatus: String = ""
    @State private var qbStreamLocal = false
    @State private var qbAppSecret: String = ""

    // Audio analyzer
    @State private var analyzerURL: String = ""
    @State private var afBusy = false
    @State private var afStatus: String = ""
    // Loaded in .task — a DB read in `body` blocked main on every render.
    @State private var afStats: (total: Int, matched: Int) = (0, 0)

    // LLM
    @State private var llmProvider: LLMConfig.Provider = .ollama
    @State private var llmBaseURL:  String = "http://localhost:11434"
    @State private var llmModel:    String = "qwen3:8b"
    @State private var llmApiKey:   String = ""
    @State private var llmSaved     = false
    @State private var ollamaModels: [String] = []
    @State private var isFetchingModels = false
    @State private var isTestingLLM = false
    @State private var llmTestStatus: String? = nil
    @State private var llmTestOK = false

    public var body: some View {
        Form {
            // Appearance
            Section(LS("settings.appearance")) {
                Picker(LS("settings.theme"), selection: $themePreset) {
                    ForEach(ThemePreset.allCases) { preset in
                        Label {
                            Text(preset.label)
                        } icon: {
                            Circle()
                                .fill(LinearGradient(colors: preset.swatch,
                                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                                .frame(width: 14, height: 14)
                                .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
                        }
                        .tag(preset)
                    }
                }
                // The custom accent + light/dark pickers only apply to "Aangepast";
                // a named preset pins its own accent and scheme.
                if themePreset == .custom {
                    Picker(LS("settings.lightMode"), selection: $themeMode) {
                        ForEach(ThemeMode.allCases) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    Picker(LS("settings.accentColour"), selection: $accent) {
                        ForEach(AccentChoice.allCases) { choice in
                            Label {
                                Text(choice.label)
                            } icon: {
                                Circle().fill(choice.color).frame(width: 12, height: 12)
                            }
                            .tag(choice)
                        }
                    }
                }
                Toggle(LS("settings.visualizerNowPlaying"), isOn: $showVisualizer)
                Picker(LS("settings.language"), selection: $appLanguage) {
                    ForEach(LocalePreference.allCases) { Text($0.label).tag($0) }
                }
            }.scoped(.device, in: scope)

            // Ambient backdrop (C6): dial the album-art wash + optional wallpaper.
            Section(LS("settings.background")) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        LT("settings.ambientIntensity")
                        Spacer()
                        Text("\(Int(ambientIntensity * 100))%")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Slider(value: $ambientIntensity, in: 0...1, step: 0.05)
                        .tint(Color.roonGold)
                    LT("settings.ambientIntensityHelp")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(LS("settings.albumArtBackground"), isOn: $ambientWallpaper)
            }.scoped(.device, in: scope)

            // Connection
            Section(LS("settings.roonConnection")) {
                LabeledContent("Status", value: client.connectionState.label)
                if let host = client.coreHost {
                    LabeledContent("Host", value: "\(host):\(client.corePort)")
                }
                HStack {
                    Button(LS("settings.disconnect")) {
                        Task { await client.disconnect() }
                    }
                    .disabled(!client.connectionState.isConnected)

                    Button(LS("settings.reauthorise"), role: .destructive) {
                        Task { await client.clearAndReauthorize() }
                    }
                    .disabled(!client.connectionState.isConnected)
                }
            }.scoped(.server, in: scope)

            Group {
            if role == .client {
                // The remote apps work like a remote: pick the server (the
                // always-on analyzer/server) and pull settings + library +
                // analyses from it in one tap. No credentials are entered here.
                Section("Server") {
                    Button {
                        Task { await syncFromServer() }
                    } label: {
                        Label(settingsSyncBusy ? "Synchroniseren…" : "Synchroniseer met server",
                              systemImage: "arrow.triangle.2.circlepath")
                    }
                    .disabled(settingsSyncBusy || client.isSyncing)

                    // Manual fallback for a server the app can't auto-discover.
                    HStack {
                        TextField("http://10.94.184.22:5767", text: $serverURL)
                            .textFieldStyle(.roundedBorder)
                        Button(LS("settings.sync")) {
                            Task { await syncFromServer(explicit: serverURL) }
                        }
                        .disabled(settingsSyncBusy || client.isSyncing
                                  || serverURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                    if let s = settingsSyncStatus {
                        Text(s).font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: Spacing.sm) {
                        // Save on commit (Enter / Bewaar), not on every keystroke —
                        // a half-typed token used to overwrite the working one.
                        SecureField(LS("settings.serverToken"), text: $serverToken)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit { saveServerToken() }
                        if tokenSaved {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(Color.roonSuccess)
                                .accessibilityLabel(LS("settings.tokenSaved"))
                                .transition(.opacity)
                        }
                        Button(LS("settings.save")) { saveServerToken() }
                            .disabled(serverToken.trimmingCharacters(in: .whitespaces) == savedServerToken)
                    }
                    .animation(Motion.quick, value: tokenSaved)
                    LT("settings.serverSyncHelp")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            }.scoped(.server, in: scope)

            // Library — counts always; sync/share controls only on the server.
            Section(LS("settings.library")) {
                LabeledContent(LS("settings.tracksInDatabase"), value: "\(client.trackCount)")
                LabeledContent(LS("settings.genresInDatabase"), value: genreCountLabel)
                LabeledContent(LS("settings.lastSync"), value: lastSync)

                if role == .server {
                    HStack {
                        Button(LS("settings.syncNow")) { client.startSync() }
                            .disabled(!client.connectionState.isConnected || client.isSyncing || client.isGenreSyncing)
                        if client.isSyncing {
                            ProgressView()
                                .controlSize(.small)
                            Text(client.syncProgress.phase)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack {
                        Button(LS("settings.syncGenres")) { client.startGenreSync() }
                            .disabled(!client.connectionState.isConnected || client.isSyncing || client.isGenreSyncing)
                        if client.isGenreSyncing {
                            ProgressView()
                                .controlSize(.small)
                            Text(client.syncProgress.phase)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Toggle(LS("settings.shareLibrary"), isOn: Binding(
                        get: { client.isLibrarySharing },
                        set: { client.setLibrarySharing(enabled: $0) }
                    ))
                    LT("settings.shareLibraryHelp")
                        .font(.caption).foregroundStyle(.secondary)

                    if client.isLibrarySharing {
                        LabeledContent(LS("settings.accessToken")) {
                            Text(LibraryShareServer.currentToken())
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Toggle(LS("settings.enforceToken"), isOn: Binding(
                            get: { LibraryShareServer.enforceToken },
                            set: { LibraryShareServer.enforceToken = $0 }
                        ))
                        LT("settings.shareTokenHelp")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.scoped(.server, in: scope)

            Group {
            if role == .server {
            // LLM
            Section("LLM / Playlist AI") {
                Picker("Provider", selection: $llmProvider) {
                    ForEach(LLMConfig.Provider.allCases, id: \.self) { p in
                        Text(p.rawValue).tag(p)
                    }
                }

                if llmProvider.usesBaseURL {
                    LabeledContent("Base URL") {
                        HStack(spacing: Spacing.sm) {
                            TextField("http://localhost:11434", text: $llmBaseURL)
                                .textFieldStyle(.roundedBorder)
                            if llmProvider == .ollama {
                                Button(isFetchingModels ? "…" : "Haal modellen op") {
                                    Task { await fetchOllamaModels() }
                                }
                                .disabled(isFetchingModels)
                            }
                        }
                    }
                    if llmProvider == .ollama, let host = client.coreHost {
                        Button {
                            llmBaseURL = "http://\(host):11434"
                            Task { await fetchOllamaModels() }
                        } label: {
                            Label(LS("settings.findAutomatically"), systemImage: "magnifyingglass")
                        }
                    }
                }

                LabeledContent("Model") {
                    if ollamaModels.isEmpty {
                        TextField(llmProvider.defaultModel.isEmpty ? "model-naam" : llmProvider.defaultModel,
                                  text: $llmModel)
                            .textFieldStyle(.roundedBorder)
                    } else {
                        Picker("Model", selection: $llmModel) {
                            ForEach(ollamaModels, id: \.self) { m in Text(m).tag(m) }
                        }
                        .labelsHidden()
                    }
                }

                if llmProvider.needsAPIKey {
                    LabeledContent(LS("settings.apiKey")) {
                        SecureField(LS("settings.pasteKeyHere"), text: $llmApiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                }

                HStack(spacing: Spacing.md) {
                    Button(llmSaved ? "Bewaard!" : "Bewaar LLM-instellingen") { saveLLMConfig() }
                    Button {
                        Task { await testLLM() }
                    } label: {
                        if isTestingLLM { ProgressView().controlSize(.small) }
                        else { Label(LS("settings.testConnection"), systemImage: "bolt.horizontal.circle") }
                    }
                    .disabled(isTestingLLM)
                }

                if let llmTestStatus {
                    Label(llmTestStatus, systemImage: llmTestOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(llmTestOK ? Color.roonSuccess : Color.roonDanger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if llmProvider == .gemini {
                    LT("settings.geminiHelp")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            // External Services
            Section(LS("settings.externalServices")) {
                LabeledContent(LS("settings.listenbrainzToken")) {
                    HStack(spacing: Spacing.sm) {
                        SecureField(LS("settings.pasteTokenHere"), text: $lbToken)
                            .textFieldStyle(.roundedBorder)
                        Button(lbSaved ? "Bewaard!" : "Bewaar") {
                            if lbToken.trimmingCharacters(in: .whitespaces).isEmpty {
                                KeychainStore.delete(key: "listenbrainz_token")
                            } else {
                                KeychainStore.save(key: "listenbrainz_token", value: lbToken.trimmingCharacters(in: .whitespaces))
                            }
                            lbSaved = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { lbSaved = false }
                        }
                    }
                }
                LT("settings.listenbrainzScrobbleHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Button(lbLovesBusy ? "Loves importeren…" : (lbLovesResult.isEmpty ? "Importeer loves als likes" : lbLovesResult)) {
                    lbLovesBusy = true
                    Task {
                        let n = await client.importListenBrainzLoves()
                        lbLovesResult = n > 0 ? "\(n) loves geïmporteerd" : "Geen nieuwe loves gevonden"
                        lbLovesBusy = false
                    }
                }
                .disabled(lbLovesBusy)
                LT("settings.listenbrainzLovedHelp")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle(LS("settings.importListenbrainzPlaylists"), isOn: Binding(
                    get: { client.lbPlaylistSyncEnabled },
                    set: { client.setListenBrainzPlaylistSync(enabled: $0) }
                ))
                LT("settings.listenbrainzPlaylistsHelp")
                    .font(.caption).foregroundStyle(.secondary)
                if client.lbPlaylistSyncEnabled {
                    Toggle(LS("settings.alsoSyncToQobuz"), isOn: Binding(
                        get: { client.lbQobuzSyncEnabled },
                        set: { client.setListenBrainzQobuzSync(enabled: $0) }
                    ))
                    .disabled(!client.qobuzConfigured)
                    Text(client.qobuzConfigured
                         ? "Maakt voor elke ListenBrainz-playlist een Qobuz-playlist “ListenBrainz · …” aan en werkt die dagelijks bij."
                         : "Stel eerst je Qobuz-account in (sectie Qobuz) om dit te kunnen gebruiken.")
                        .font(.caption).foregroundStyle(.secondary)

                    Button(LS("settings.syncPlaylistsNow")) { client.syncListenBrainzPlaylistsNow() }
                    if !client.lbPlaylistSyncStatus.isEmpty {
                        Text(client.lbPlaylistSyncStatus)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            // Discogs (F7 — Discogs Labels discovery producer)
            Section("Discogs") {
                LabeledContent(LS("settings.personalAccessToken")) {
                    HStack(spacing: Spacing.sm) {
                        SecureField(LS("settings.pasteTokenHere"), text: $discogsToken)
                            .textFieldStyle(.roundedBorder)
                        Button(discogsSaved ? "Bewaard!" : "Bewaar") {
                            if discogsToken.trimmingCharacters(in: .whitespaces).isEmpty {
                                KeychainStore.delete(key: "discogs_token")
                            } else {
                                KeychainStore.save(key: "discogs_token", value: discogsToken.trimmingCharacters(in: .whitespaces))
                            }
                            discogsSaved = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { discogsSaved = false }
                        }
                    }
                }
                LT("settings.discogsHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Last.fm
            Section("Last.fm") {
                if lfConnected {
                    LabeledContent(LS("settings.connectedAs"), value: lfUsername.isEmpty ? "✓" : lfUsername)
                    Toggle(LS("settings.scrobbleFromApp"), isOn: $lfScrobbleFromApp)
                    LT("settings.lastfmDoubleScrobbleHelp")
                        .font(.caption).foregroundStyle(.secondary)
                    Button {
                        Task { await client.importLastfmHistory() }
                    } label: {
                        Label(client.lastfmImportInProgress ? "Bezig met importeren…" : "Importeer volledige Last.fm-historie",
                              systemImage: "square.and.arrow.down")
                    }
                    .disabled(client.lastfmImportInProgress)
                    if client.lastfmImportInProgress {
                        ProgressView()
                    }
                    if !client.lastfmImportStatus.isEmpty {
                        Text(client.lastfmImportStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    LT("settings.lastfmImportHelp")
                        .font(.caption).foregroundStyle(.secondary)

                    Divider()
                    Toggle(LS("settings.importTopTracksAsPlaylists"), isOn: Binding(
                        get: { client.lastfmPlaylistSyncEnabled },
                        set: { client.setLastfmPlaylistSync(enabled: $0) }
                    ))
                    LT("settings.lastfmTopTracksHelp")
                        .font(.caption).foregroundStyle(.secondary)
                    if client.lastfmPlaylistSyncEnabled {
                        Toggle(LS("settings.alsoSyncToQobuz"), isOn: Binding(
                            get: { client.lastfmQobuzSyncEnabled },
                            set: { client.setLastfmQobuzSync(enabled: $0) }
                        ))
                        .disabled(!client.qobuzConfigured)
                        Text(client.qobuzConfigured
                             ? "Maakt voor elke lijst een Qobuz-playlist “Last.fm · …” aan en werkt die dagelijks bij."
                             : "Stel eerst je Qobuz-account in (sectie Qobuz) om dit te kunnen gebruiken.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button(LS("settings.syncPlaylistsNow")) { client.syncLastfmPlaylistsNow() }
                        if !client.lastfmPlaylistSyncStatus.isEmpty {
                            Text(client.lastfmPlaylistSyncStatus)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    Button(LS("settings.disconnectLastfm"), role: .destructive) {
                        KeychainStore.delete(key: "lastfm_session_key")
                        KeychainStore.delete(key: "lastfm_username")
                        lfConnected = false; lfUsername = ""; lfStatus = ""
                    }
                } else {
                    LabeledContent(LS("settings.apiKey")) {
                        SecureField(LS("settings.lastfmApiKey"), text: $lfApiKey)
                            .textFieldStyle(.roundedBorder)
                    }
                    LabeledContent(LS("settings.apiSecret")) {
                        SecureField(LS("settings.lastfmApiSecret"), text: $lfApiSecret)
                            .textFieldStyle(.roundedBorder)
                    }
                    if lfPendingToken == nil {
                        Button(lfBusy ? "…" : "Koppel Last.fm") { Task { await lfStartAuth() } }
                            .disabled(lfBusy || lfApiKey.isEmpty || lfApiSecret.isEmpty)
                    } else {
                        Button(lfBusy ? "…" : "Ga verder (na goedkeuren)") { Task { await lfCompleteAuth() } }
                            .disabled(lfBusy)
                    }
                }
                if !lfStatus.isEmpty {
                    Text(lfStatus).font(.caption).foregroundStyle(.secondary)
                }
                LT("settings.lastfmScrobbleHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Qobuz
            Section("Qobuz") {
                LabeledContent(LS("settings.email")) {
                    TextField(LS("settings.emailPlaceholder"), text: $qbEmail)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.username)
                }
                LabeledContent(LS("settings.password")) {
                    SecureField(LS("settings.qobuzPassword"), text: $qbPassword)
                        .textFieldStyle(.roundedBorder)
                }
                Button(qbBusy ? "Verifiëren…" : "Bewaar & verifieer") { Task { await saveQobuz() } }
                    .disabled(qbBusy || qbEmail.isEmpty || qbPassword.isEmpty)
                if !qbStatus.isEmpty {
                    Text(qbStatus).font(.caption).foregroundStyle(.secondary)
                }
                LT("settings.qobuzHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            } // end role == .server
            }.scoped(.server, in: scope)

            // Also device-local: `qobuz_local_stream_enabled` is UserDefaults on
            // THIS device, so behind the server gate a phone could never turn it
            // on — Qobuz tracks stayed silently skipped there with no way to
            // change it. The credentials it needs arrive via settings sync.
            Section(LS("settings.qobuzLocalStreaming")) {
                Toggle(LS("settings.playQobuzHere"), isOn: $qbStreamLocal)
                    .onChange(of: qbStreamLocal) { _, v in client.qobuzLocalStreamEnabled = v }
                    .disabled(!client.qobuzConfigured)
                if qbStreamLocal {
                    LabeledContent("app_secret") {
                        SecureField("Qobuz web-player app_secret", text: $qbAppSecret)
                            .textFieldStyle(.roundedBorder)
                    }
                    Button(LS("settings.saveAppSecret")) { client.qobuzAppSecret = qbAppSecret }
                        .disabled(qbAppSecret.isEmpty)
                }
                LT("settings.qobuzLocalHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }.scoped(.device, in: scope)

            Group {
            if role == .server {
            // Audio analyzer — configures the analyzer host itself, so it stays
            // server-only; a client receives the results through settings sync.
            Section(LS("settings.audioAnalyzer")) {
                LabeledContent(LS("settings.analyzerURL")) {
                    TextField("http://10.94.184.22:5766", text: $analyzerURL)
                        .textFieldStyle(.roundedBorder)
                }
                if let host = client.coreHost {
                    Button {
                        analyzerURL = "http://\(host):5766"
                    } label: {
                        Label(LS("settings.findAutomatically"), systemImage: "magnifyingglass")
                    }
                }
                LabeledContent(LS("settings.syncedFeatures"), value: "\(afStats.matched) gematcht / \(afStats.total) totaal")
                Button(afBusy ? "Synchroniseren…" : "Bewaar & sync kenmerken") { Task { await syncAnalyzer() } }
                    .disabled(afBusy || analyzerURL.isEmpty)
                Button(LS("settings.diagnoseMatchRate")) { Task { await diagnoseAnalyzer() } }
                    .disabled(afBusy || analyzerURL.isEmpty)
                if !afStatus.isEmpty {
                    Text(afStatus).font(.caption).foregroundStyle(.secondary)
                }
                Toggle(LS("settings.sonicEmbeddings"), isOn: Binding(
                    get: { client.useSonicEmbeddings },
                    set: { client.useSonicEmbeddings = $0 }))
                LT("settings.clapHelp")
                    .font(.caption).foregroundStyle(.secondary)
                LT("settings.analyzerHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            } // end role == .server
            }.scoped(.server, in: scope)

            // Playback on THIS device — deliberately outside the server gate.
            //
            // These four sat inside `role == .server`, so on a phone (always
            // `.client`) they were invisible: loudness levelling, the cellular
            // AAC transcode, the audio cache and offline downloads were all
            // hidden on the one device they exist for. Nothing here configures
            // the server; every setting is about how audio plays right here.
            LoudnessSettingsSection().scoped(.device, in: scope)

            TranscodeSettingsSection().scoped(.device, in: scope)

            AudioCacheSettingsSection().scoped(.device, in: scope)

            OfflineDownloadsSection().scoped(.device, in: scope)

            // About
            Section(LS("settings.about")) {
                LabeledContent(LS("settings.version"), value: appVersion)
                LabeledContent("Protocol", value: "MOO/1 · SOOD · GRDB 6")
                #if os(macOS)
                LabeledContent("Platform", value: "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
                #else
                LabeledContent("Platform", value: "iOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
                #endif
                NavigationLink {
                    LogConsoleView()
                } label: {
                    Label(LS("settings.viewShareLog"), systemImage: "doc.text.magnifyingglass")
                }
            }
        }.scoped(.device, in: scope)
        .formStyle(.grouped)
        .navigationTitle(scopeTitle)
        #if os(macOS)
        .frame(width: 440)
        #endif
        // A DB read for the analyzer section; pointless on the device page.
        .task {
            guard scope != .device else { return }
            afStats = await client.audioFeaturesStats()
        }
        .onAppear { loadSettingsState() }
        .onChange(of: client.isSyncing) { _, _ in refreshLastSync() }
    }

    private var scopeTitle: String {
        switch scope {
        case .device: LS("settings.thisDevice")
        case .server: LS("settings.serverAndServices")
        case .all:    LS("nav.settings")
        }
    }

    /// Loads every field from UserDefaults + Keychain into local @State. Called
    /// on first render and again after a settings sync from the Mac, so the UI
    /// immediately reflects the imported values.
    private func saveServerToken() {
        let t = serverToken.trimmingCharacters(in: .whitespaces)
        serverToken = t
        LibraryShareServer.setConfiguredToken(t)
        savedServerToken = t
        tokenSaved = true
        Haptics.success()
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            tokenSaved = false
        }
    }

    private func loadSettingsState() {
        refreshLastSync()
        lbToken = KeychainStore.load(key: "listenbrainz_token") ?? ""
        discogsToken = KeychainStore.load(key: "discogs_token") ?? ""
        lfApiKey    = KeychainStore.load(key: "lastfm_api_key") ?? ""
        lfApiSecret = KeychainStore.load(key: "lastfm_api_secret") ?? ""
        lfUsername  = KeychainStore.load(key: "lastfm_username") ?? ""
        lfConnected = !(KeychainStore.load(key: "lastfm_session_key") ?? "").isEmpty
        qbEmail    = KeychainStore.load(key: "qobuz_email") ?? ""
        qbPassword = KeychainStore.load(key: "qobuz_password") ?? ""
        qbStreamLocal = client.qobuzLocalStreamEnabled
        qbAppSecret = client.qobuzAppSecret ?? ""
        analyzerURL = client.analyzerURL
        let cfg = LLMConfigStore.load()
        llmProvider = cfg.provider
        llmBaseURL  = cfg.baseURL
        llmModel    = cfg.model
        llmApiKey   = cfg.apiKey
        if cfg.provider == .ollama {
            Task { await fetchOllamaModels() }
        }
    }

    private var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(v) (build \(b))"
    }

    private func refreshLastSync() {
        // `syncStateValue` is a synchronous GRDB `pool.read`; running it inline
        // here blocks the main thread (it stalls behind an in-flight import
        // write). Hop off the MainActor for the read, then assign on return.
        guard let db = client.database else { lastSync = "Nooit"; return }
        Task {
            let value = await Task.detached { (try? db.syncStateValue(forKey: "last_sync")) ?? nil }.value
            lastSync = value ?? "Nooit"
        }
    }

    /// Client role: pull settings + library + analyses from the server. With an
    /// explicit URL, sync that host; otherwise auto-discover the server.
    private func syncFromServer(explicit: String? = nil) async {
        settingsSyncBusy = true; defer { settingsSyncBusy = false }
        let trimmed = explicit?.trimmingCharacters(in: .whitespaces)
        if let trimmed, !trimmed.isEmpty {
            settingsSyncStatus = "Synchroniseren met \(trimmed)…"
            if let r = await client.syncEverythingFromServer(baseURL: trimmed) {
                loadSettingsState()
                settingsSyncStatus = "Klaar — \(r.tracks) tracks, \(r.features) kenmerken ✓"
            } else {
                settingsSyncStatus = "Mislukt — draait de RoonSage-server (analyzer) op \(trimmed)?"
            }
        } else {
            settingsSyncStatus = "Server zoeken op poort 5767…"
            if let r = await client.autoSyncEverythingFromServer() {
                serverURL = r.source
                loadSettingsState()
                settingsSyncStatus = "Klaar — \(r.tracks) tracks, \(r.features) kenmerken van \(r.source) ✓"
            } else {
                settingsSyncStatus = "Geen server gevonden — start de RoonSage-server (analyzer) op je always-on Mac."
            }
        }
    }

    private func saveLLMConfig() {
        LLMConfigStore.save(LLMConfig(provider: llmProvider, baseURL: llmBaseURL, model: llmModel, apiKey: llmApiKey))
        llmSaved = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { llmSaved = false }
    }

    /// Fire a tiny completion against the *current* (unsaved) settings so the user
    /// can confirm provider/key/model before relying on it. Uses the same
    /// loopback-retargeting as real generation so a thin client tests the right host.
    private func testLLM() async {
        isTestingLLM = true; llmTestStatus = nil
        defer { isTestingLLM = false }
        var cfg = LLMConfig(provider: llmProvider, baseURL: llmBaseURL, model: llmModel, apiKey: llmApiKey)
        // Apply the same loopback → core-host retargeting as real generation so a
        // thin client tests the host where Ollama actually runs.
        cfg = client.effectiveLLMConfig(cfg)
        if let err = await LLMClient.shared.test(config: cfg) {
            llmTestStatus = err
            llmTestOK = false
        } else {
            llmTestStatus = "Verbinding OK — \(cfg.provider.rawValue) (\(cfg.effectiveModel)) antwoordt."
            llmTestOK = true
        }
    }

    // MARK: - Audio analyzer

    private func syncAnalyzer() async {
        afBusy = true; defer { afBusy = false }
        let url = analyzerURL.trimmingCharacters(in: .whitespaces)
        client.analyzerURL = url
        afStatus = "Kenmerken ophalen…"
        if let r = await client.syncAudioFeatures(from: url) {
            let pct = Int((r.matchRate * 100).rounded())
            afStatus = "\(r.featureRows) kenmerken gesynct — \(r.exactMatched) exact + \(r.fuzzyMatched) fuzzy = \(pct)% van \(r.libraryTracks) tracks gematcht."
            afStats = await client.audioFeaturesStats()
        } else {
            afStatus = "Kon de analyzer niet bereiken op \(url). Draait `roonsage-analyzer serve`?"
        }
    }

    private func diagnoseAnalyzer() async {
        afBusy = true; defer { afBusy = false }
        let url = analyzerURL.trimmingCharacters(in: .whitespaces)
        afStatus = "Diagnosticeren…"
        guard let r = await client.diagnoseAudioFeatures(from: url) else {
            afStatus = "Kon de analyzer niet bereiken op \(url)."
            return
        }
        let pct = Int((r.matchRate * 100).rounded())
        var msg = "Match-percentage \(pct)%: \(r.exactMatched) exact + \(r.fuzzyMatched) fuzzy / \(r.libraryTracks) tracks (\(r.unmatched) niet gematcht, \(r.featureRows) kenmerken). Alleen-lezen — niets gewijzigd."
        if !r.sampleUnmatched.isEmpty {
            msg += "\n\nVoorbeelden zonder match:\n• " + r.sampleUnmatched.prefix(12).joined(separator: "\n• ")
        }
        afStatus = msg
    }

    // MARK: - Qobuz

    private func saveQobuz() async {
        qbBusy = true; defer { qbBusy = false }
        let email = qbEmail.trimmingCharacters(in: .whitespaces)
        let pw = qbPassword
        KeychainStore.save(key: "qobuz_email", value: email)
        KeychainStore.save(key: "qobuz_password", value: pw)
        if let name = await QobuzClient.shared.verify(email: email, password: pw) {
            qbStatus = "Verbonden als \(name)."
        } else {
            qbStatus = "Inloggen mislukt — controleer je e-mail en wachtwoord."
        }
    }

    // MARK: - Last.fm auth flow

    private func lfStartAuth() async {
        lfBusy = true; defer { lfBusy = false }
        let key = lfApiKey.trimmingCharacters(in: .whitespaces)
        let secret = lfApiSecret.trimmingCharacters(in: .whitespaces)
        KeychainStore.save(key: "lastfm_api_key", value: key)
        KeychainStore.save(key: "lastfm_api_secret", value: secret)
        guard let token = await LastfmClient.shared.getToken(apiKey: key, apiSecret: secret) else {
            lfStatus = "Kon geen Last.fm-token krijgen — controleer je API-sleutel en -secret."
            return
        }
        lfPendingToken = token
        if let url = LastfmClient.shared.authURL(apiKey: key, token: token) {
            openURL(url)
        }
        lfStatus = "Keur RoonSage goed in de browser en klik daarna op Ga verder."
    }

    private func lfCompleteAuth() async {
        guard let token = lfPendingToken else { return }
        lfBusy = true; defer { lfBusy = false }
        let key = lfApiKey.trimmingCharacters(in: .whitespaces)
        let secret = lfApiSecret.trimmingCharacters(in: .whitespaces)
        guard let session = await LastfmClient.shared.getSession(apiKey: key, apiSecret: secret, token: token) else {
            lfStatus = "Goedkeuring nog niet afgerond — keur goed in de browser en klik daarna op Ga verder."
            return
        }
        KeychainStore.save(key: "lastfm_session_key", value: session.key)
        KeychainStore.save(key: "lastfm_username", value: session.name)
        lfUsername = session.name
        lfConnected = true
        lfPendingToken = nil
        lfStatus = "Verbonden als \(session.name)."
    }

    private func fetchOllamaModels() async {
        isFetchingModels = true
        defer { isFetchingModels = false }
        let models = await LLMConfigStore.fetchOllamaModels(baseURL: llmBaseURL)
        ollamaModels = models
        if !models.isEmpty, !models.contains(llmModel) {
            llmModel = models.first ?? llmModel
        }
    }
}

/// Music pinned to this device: what you asked to take with you.
///
/// Distinct from the cache below it — that fills itself with whatever you played
/// and is pruned; this is explicit, lives outside Caches/, and only you remove it.
@MainActor
struct OfflineDownloadsSection: View {
    @Environment(RoonClient.self) private var client
    @State private var sizeBytes = 0
    @State private var count = 0
    @AppStorage(LocalAudioCache.downloadOnCellularKey) private var allowOnCellular = false

    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        return f
    }()

    var body: some View {
        Section(LS("downloads.sectionTitle")) {
            if let p = client.downloadProgress, !p.isFinished {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    ProgressView(value: p.fraction)
                    HStack {
                        Text(p.currentTitle ?? "").font(.caption).lineLimit(1)
                        Spacer()
                        Text("\(p.completed + p.failed)/\(p.total)")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                Button(LS("downloads.cancel"), role: .cancel) { client.cancelDownloads() }
            }
            NavigationLink {
                DownloadsView()
            } label: {
                LabeledContent(LS("downloads.onDevice"),
                               value: "\(count) · \(Self.sizeFormatter.string(fromByteCount: Int64(sizeBytes)))")
            }
            Toggle(LS("downloads.allowOnCellular"), isOn: $allowOnCellular)
            Button(LS("downloads.removeAll"), role: .destructive) {
                Task { await client.removeAllOfflineTracks(); await refresh() }
            }
            .disabled(count == 0)
            Text(LS("downloads.explainer"))
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await refresh() }
        .task(id: client.downloadProgress?.isFinished) { await refresh() }
    }

    private func refresh() async {
        sizeBytes = LocalAudioCache.downloadsSizeBytes()
        count = client.offlineKeys.count
    }
}

/// Disk cache of already-streamed audio: what makes stepping back, repeating
/// and replaying instant instead of a re-fetch. Filling it costs a second
/// download, so it is skipped on mobile data — same "onderweg" notion the
/// transcode policy above uses.
struct AudioCacheSettingsSection: View {
    @AppStorage(LocalAudioCache.enabledKey) private var enabled = true
    @AppStorage(LocalAudioCache.limitKey) private var limitMB = 2048
    @State private var sizeBytes = 0

    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        return f
    }()

    var body: some View {
        Section(LS("settings.keepMusicOnDevice")) {
            Toggle(LS("settings.keepWhatYouPlay"), isOn: $enabled)
            if enabled {
                Picker(LS("settings.maximum"), selection: $limitMB) {
                    Text("1 GB").tag(1024)
                    Text("2 GB").tag(2048)
                    Text("5 GB").tag(5120)
                    Text("10 GB").tag(10240)
                }
                LabeledContent(LS("settings.currentlyUsed"),
                               value: Self.sizeFormatter.string(fromByteCount: Int64(sizeBytes)))
                Button(LS("settings.emptyCache"), role: .destructive) {
                    LocalAudioCache.clear()
                    sizeBytes = 0
                }
                .disabled(sizeBytes == 0)
            }
            LT("settings.audioCacheHelp")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task { sizeBytes = LocalAudioCache.sizeBytes() }
    }
}

/// Loudness normalization for on-device playback (LMS-style ReplayGain UX).
/// Self-contained: binds straight to the `LocalLoudness` UserDefaults keys and
/// pokes the live player so a change is audible without a track skip.
struct LoudnessSettingsSection: View {
    @AppStorage("local_loudness_mode") private var modeRaw = LocalLoudness.Mode.off.rawValue
    @AppStorage("local_loudness_preamp_db") private var preampDB = 0.0

    var body: some View {
        Section(LS("settings.loudnessNormalisation")) {
            Picker(LS("settings.mode"), selection: $modeRaw) {
                LT("settings.off").tag(LocalLoudness.Mode.off.rawValue)
                LT("settings.perTrack").tag(LocalLoudness.Mode.track.rawValue)
                LT("settings.perAlbum").tag(LocalLoudness.Mode.album.rawValue)
            }
            .onChange(of: modeRaw) { _, _ in LocalPlaybackController.shared.reapplyLoudness() }
            if modeRaw != LocalLoudness.Mode.off.rawValue {
                LabeledContent("Pre-amp") {
                    HStack {
                        Slider(value: $preampDB, in: -12...12, step: 1)
                            .onChange(of: preampDB) { _, _ in
                                LocalPlaybackController.shared.reapplyLoudness()
                            }
                        Text(String(format: "%+.0f dB", preampDB))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }
            }
            LT("settings.loudnessHelp")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// AAC-transcoding for on-device playback over the network (LMS-style
/// bandwidth setting): stream the original at home, a lean AAC on the road.
struct TranscodeSettingsSection: View {
    // Defaults come from LocalTranscode, never repeated here: @AppStorage binds
    // to the same keys the policy reads, so a literal would silently drift and
    // this screen would show a setting the app isn't using.
    @AppStorage("local_transcode_mode") private var modeRaw = LocalTranscode.defaultMode.rawValue
    @AppStorage("local_transcode_kbps") private var kbps = LocalTranscode.defaultBitrateKbps

    var body: some View {
        Section(LS("settings.streamingOnTheGo")) {
            Picker(LS("settings.transcodeToAAC"), selection: $modeRaw) {
                LT("settings.never").tag(LocalTranscode.Mode.off.rawValue)
                LT("settings.cellularOnly").tag(LocalTranscode.Mode.cellular.rawValue)
                LT("settings.always").tag(LocalTranscode.Mode.always.rawValue)
            }
            if modeRaw != LocalTranscode.Mode.off.rawValue {
                Picker("Bitrate", selection: $kbps) {
                    LT("settings.bitrate64").tag(64)
                    LT("settings.bitrate96").tag(96)
                    Text("128 kbps").tag(128)   // blijft staan: wie dit ooit koos, houdt een geldige selectie
                    Text("192 kbps").tag(192)
                    LT("settings.bitrate256").tag(256)
                }
            }
            LT("settings.transcodeHelp")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
