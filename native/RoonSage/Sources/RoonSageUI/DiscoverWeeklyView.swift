import RoonSageCore
import SwiftUI

/// "Ontdek Wekelijks" — the library-first weekly discovery playlist. A hub instap
/// showing the current week's selection (AI title + description + generation date),
/// its tracklist (with a clear "nog niet in je bibliotheek" flag on Qobuz/
/// ListenBrainz enrichment picks), a "Speel nu" action, and a manual "Ververs nu".
///
/// The server builds and stores it; this view just fetches it (`client.discoverWeekly`)
/// and can ask the server to rebuild (`client.refreshDiscoverWeekly`). Shared by
/// macOS + iOS — no platform chrome.
@MainActor
public struct DiscoverWeeklyView: View {
    @Environment(RoonClient.self) private var client

    @State private var playlist: DiscoverWeeklyPlaylist?
    @State private var loading = true
    @State private var refreshing = false
    @State private var errorText: String?
    @State private var actionMessage: String?   // transient "Afspelen gestart…" banner

    public init() {}

    /// Strip placeholder "Unknown Artist" fragments a source (ListenBrainz/Qobuz)
    /// sometimes leaves in a joined credit ("Alan Parsons / Unknown Artist"), so
    /// the row shows a clean name instead of the raw metadata.
    private func cleanArtist(_ artist: String?) -> String {
        guard let artist, !artist.isEmpty else { return LS("discoverWeekly.unknownArtist") }
        let parts = artist
            .components(separatedBy: CharacterSet(charactersIn: "/;"))
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0.caseInsensitiveCompare("Unknown Artist") != .orderedSame }
        return parts.isEmpty ? LS("discoverWeekly.unknownArtist") : parts.joined(separator: " / ")
    }

    public var body: some View {
        List {
            ZoneHintBanner().plainCardRow()
            if let pl = playlist {
                header(pl).plainCardRow()
                tracksSection(pl)
            } else if loading {
                loadingState.plainCardRow()
            } else if let errorText {
                ErrorStateView(errorText) { Task { await load() } }.plainCardRow()
            } else {
                emptyState.plainCardRow()
            }
        }
        .navigationTitle(LS("discoverWeekly.navTitle"))
        .toolbar {
            Button {
                Task { await refreshNow() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .disabled(refreshing)
            .help(LS("discoverWeekly.refreshHelp"))
            .accessibilityLabel(LS("discoverWeekly.refreshA11y"))
        }
        .ambientSurface()
        .animation(Motion.standard, value: loading)
        .overlay(alignment: .top) {
            if let actionMessage {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "play.circle.fill").foregroundStyle(Color.roonGold)
                    Text(actionMessage).font(.caption).lineLimit(2)
                }
                .padding(.horizontal, Spacing.md).padding(.vertical, Spacing.sm)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.top, Spacing.sm)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .task { await load() }
    }

    private func showActionMessage(_ text: String) {
        withAnimation(Motion.quick) { actionMessage = text }
        Task {
            try? await Task.sleep(for: .seconds(4))
            withAnimation(Motion.quick) { actionMessage = nil }
        }
    }

    // MARK: Header card

    private func header(_ pl: DiscoverWeeklyPlaylist) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            HStack(alignment: .top, spacing: Spacing.md) {
                AlbumArtView(imageKey: pl.imageKey, size: 96, cornerRadius: Radius.lg)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(pl.title)
                        .font(.title3).bold()
                        .fixedSize(horizontal: false, vertical: true)
                    Text(pl.description)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(subtitle(pl))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: Spacing.sm) {
                Button {
                    Haptics.tap()
                    let target = client.selectedZone?.displayName ?? RoonClient.localOutputName
                    Task {
                        await client.playToActiveOutput(pl.trackRecords)
                        // Optimistic confirm (a zone's queue loads server-side); a
                        // real failure still surfaces via the global error toast.
                        if client.lastActionError == nil { showActionMessage("Afspelen gestart op ‘\(target)’ — \(pl.tracks.count) tracks.") }
                    }
                } label: {
                    Label(LS("bm.playNow"), systemImage: "play.fill")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(!client.hasActiveOutput)

                Button {
                    Task { await refreshNow() }
                } label: {
                    if refreshing {
                        ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                    } else {
                        Label(LS("discoverWeekly.refreshNow"), systemImage: "arrow.clockwise")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.bordered)
                .disabled(refreshing)
            }
        }
        .padding(Spacing.md)
    }

    // MARK: Tracks

    private func tracksSection(_ pl: DiscoverWeeklyPlaylist) -> some View {
        Section(LS("discoverWeekly.tracksSection")) {
            ForEach(Array(pl.tracks.enumerated()), id: \.offset) { idx, t in
                HStack(spacing: Spacing.md) {
                    Text("\(idx + 1)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .frame(width: 20, alignment: .trailing)
                    AlbumArtView(imageKey: t.imageKey, size: 44)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.title.displayTitle).font(.body).lineLimit(2)
                        Text(cleanArtist(t.artist))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if t.notInLibrary {
                        LT("discoverWeekly.notInLibrary")
                            .font(.caption2)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.roonGold.opacity(0.18), in: Capsule())
                            .foregroundStyle(Color.roonGold)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(idx + 1). \(t.title), \(cleanArtist(t.artist))\(t.notInLibrary ? ", nog niet in je bibliotheek" : "")")
            }
        }
    }

    // MARK: States

    private var loadingState: some View {
        HStack { Spacer(); ProgressView(LS("discoverWeekly.loading")); Spacer() }
            .padding(.vertical, Spacing.xl)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(LS("discoverWeekly.emptyTitle"), systemImage: "sparkles")
        } description: {
            LT("discoverWeekly.emptyDescription")
        } actions: {
            Button {
                Task { await refreshNow() }
            } label: {
                Label(refreshing ? LS("discoverWeekly.busy") : LS("discoverWeekly.generateNow"), systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .disabled(refreshing)
        }
    }

    // MARK: Data

    private func load() async {
        loading = true
        errorText = nil
        do { playlist = try await client.discoverWeeklyChecked() }
        catch { errorText = error.localizedDescription }
        loading = false
    }

    private func refreshNow() async {
        guard !refreshing else { return }
        refreshing = true
        do {
            if let fresh = try await client.refreshDiscoverWeeklyChecked() { playlist = fresh }
            // A successful build clears any prior "kon niet bouwen" error.
            if playlist != nil { errorText = nil }
        } catch {
            Haptics.error()
            // Only take over the screen with an error when there's nothing to show;
            // a failed refresh over existing content just buzzes and keeps the list.
            if playlist == nil { errorText = error.localizedDescription }
        }
        refreshing = false
    }

    // MARK: Formatting

    private func subtitle(_ pl: DiscoverWeeklyPlaylist) -> String {
        var parts: [String] = []
        if let date = Self.isoParser.date(from: pl.generatedAt) {
            parts.append(LS("Gegenereerd op \(Self.dateFormatter.string(from: date))"))
        } else if !pl.weekKey.isEmpty {
            parts.append(LS("Week \(pl.weekKey)"))
        }
        parts.append(LS("\(pl.tracks.count) tracks"))
        if pl.discoveryCount > 0 { parts.append(LS("\(pl.discoveryCount) buiten je bibliotheek")) }
        return parts.joined(separator: " · ")
    }

    private static let isoParser = ISO8601DateFormatter()
    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "nl_NL")
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}
