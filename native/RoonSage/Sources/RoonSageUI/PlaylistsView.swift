import SwiftUI
import RoonSageCore

/// Saved local playlists — list, expand to view tracks, play to the selected
/// zone, or delete. Playlists are created via curation (save_playlist in the
/// MCP flow) and persist across library re-syncs.
@MainActor
public struct PlaylistsView: View {
    public init() {}
    @Environment(RoonClient.self) private var client

    @State private var playlists: [DatabaseManager.PlaylistSummary] = []
    @State private var expanded: Int64? = nil
    @State private var tracks: [TrackRecord] = []
    @State private var statusBanner: String? = nil
    /// nil = in progress (spinner), true = success (green), false = failure (red).
    @State private var statusOK: Bool? = nil
    @State private var hasLoaded = false
    @State private var pendingDelete: DatabaseManager.PlaylistSummary? = nil
    @Environment(\.navigateTo) private var navigateTo

    public var body: some View {
        Group {
            if !hasLoaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if playlists.isEmpty {
                ContentUnavailableView {
                    Label(LS("playlists.emptyTitle"), systemImage: "list.star")
                } description: {
                    LT("playlists.emptyDescription")
                } actions: {
                    Button {
                        Haptics.tap()
                        navigateTo(.generate)
                    } label: {
                        Label(LS("playlists.generatePlaylist"), systemImage: "wand.and.stars")
                    }
                    .buttonStyle(.borderedProminent)
                }
            } else {
                List {
                    ForEach(playlists, id: \.id) { pl in
                        Section {
                            row(pl)
                            if expanded == pl.id {
                                ForEach(Array(tracks.enumerated()), id: \.offset) { i, t in
                                    HStack(spacing: Spacing.sm) {
                                        Text("\(i + 1).")
                                            .foregroundStyle(.tertiary)
                                            .frame(width: 30, alignment: .trailing)
                                        AlbumArtView(imageKey: t.imageKey, size: 32)
                                        Text(t.title)
                                        if let a = t.artist {
                                            Text("— \(a)").foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                    }
                                    .font(.callout)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(LS("nav.playlists"))
        .toolbar {
            Button(action: reload) { Image(systemName: "arrow.clockwise") }
                .help(LS("playlists.refresh"))
                .accessibilityLabel(LS("playlists.refresh"))
        }
        .onAppear(perform: reload)
        .confirmationDialog(
            LS("playlists.deleteConfirmTitle"),
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(LS("action.delete"), role: .destructive) {
                if let pl = pendingDelete { delete(pl) }
                pendingDelete = nil
            }
            Button(LS("playlists.cancel"), role: .cancel) { pendingDelete = nil }
        } message: {
            if let name = pendingDelete?.name {
                LT("\(name) wordt definitief verwijderd.")
            }
        }
        .safeAreaInset(edge: .bottom) {
            if let statusBanner {
                Label {
                    Text(statusBanner)
                } icon: {
                    if let statusOK {
                        Image(systemName: statusOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    } else {
                        ProgressView().controlSize(.small)
                    }
                }
                .font(.caption)
                .foregroundStyle(statusOK == nil ? AnyShapeStyle(.secondary)
                                 : AnyShapeStyle(statusOK! ? Color.roonSuccess : Color.roonDanger))
                .padding(Spacing.sm)
                .frame(maxWidth: .infinity)
                .background(.bar)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(Motion.standard, value: statusBanner)
    }

    /// Source badge for an imported playlist (nil for user-curated ones).
    private func sourceBadge(_ source: String?) -> (text: String, color: Color)? {
        switch source {
        case "listenbrainz": return ("ListenBrainz", Color.roonGold)
        case "lastfm":       return ("Last.fm", Color(red: 0.79, green: 0.04, blue: 0.04))
        default:             return nil
        }
    }

    @ViewBuilder
    private func row(_ pl: DatabaseManager.PlaylistSummary) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(pl.name).font(.headline)
                    if let badge = sourceBadge(pl.source) {
                        Text(badge.text)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(badge.color.opacity(0.18), in: Capsule())
                            .foregroundStyle(badge.color)
                            .accessibilityLabel(LS("Bron: \(badge.text)"))
                    }
                }
                Text("\(pl.trackCount) nummers · \(pl.createdAt.prefix(10))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { Task { await play(pl) } } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!client.hasActiveOutput)
            .accessibilityLabel(LS("playlists.playPlaylist"))
            .help(client.hasActiveOutput
                  ? LS("Speel af in \(client.selectedZone?.displayName ?? RoonClient.localOutputName)")
                  : LS("playlists.chooseZoneFirst"))

            if client.qobuzConfigured {
                Button { saveToQobuz(pl) } label: { Image(systemName: "cloud") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(LS("playlists.saveToQobuz"))
                    .help(LS("playlists.saveToQobuz"))
            }

            Button { toggle(pl) } label: {
                Image(systemName: expanded == pl.id ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(expanded == pl.id ? LS("playlists.hideTracks") : LS("playlists.showTracks"))

            Button(role: .destructive) { pendingDelete = pl } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(LS("playlists.deletePlaylist"))
        }
    }

    private func saveToQobuz(_ pl: DatabaseManager.PlaylistSummary) {
        Task {
            let tracks = await client.playlistTracks(id: pl.id)
            guard !tracks.isEmpty else { return }
            statusOK = nil
            statusBanner = LS("“\(pl.name)” bewaren in Qobuz…")
            if let r = await client.saveToQobuz(name: pl.name, tracks: tracks) {
                statusOK = true
                statusBanner = "“\(pl.name)” → Qobuz: \(r.matched)/\(r.total) gematcht."
                Haptics.success()
            } else {
                statusOK = false
                statusBanner = LS("playlists.saveToQobuzFailed")
                Haptics.error()
            }
        }
    }

    private func reload() {
        Task {
            playlists = await client.playlists()
            hasLoaded = true
        }
    }

    private func toggle(_ pl: DatabaseManager.PlaylistSummary) {
        if expanded == pl.id {
            expanded = nil
        } else {
            expanded = pl.id
            Task { tracks = await client.playlistTracksForDisplay(id: pl.id) }
        }
    }

    private func play(_ pl: DatabaseManager.PlaylistSummary) async {
        Haptics.tap()
        statusOK = nil
        statusBanner = LS("“\(pl.name)” starten…")
        let played = await client.playPlaylist(id: pl.id)
        if played > 0 {
            statusOK = true
            statusBanner = String(format: LS("playlists.nowPlayingOn"), pl.name,
                                  client.selectedZone?.displayName ?? RoonClient.localOutputName, played)
            Haptics.success()
        } else {
            statusOK = false
            statusBanner = LS("“\(pl.name)” kon niet starten — geen van de tracks was beschikbaar.")
            Haptics.error()
        }
    }


    private func delete(_ pl: DatabaseManager.PlaylistSummary) {
        client.deletePlaylist(id: pl.id)
        if expanded == pl.id { expanded = nil }
        reload()
    }
}
