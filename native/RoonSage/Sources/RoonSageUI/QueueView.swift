import RoonSageCore
import SwiftUI

/// The selected zone's Roon play queue. Tap a track to jump to it (play from
/// here). Roon's extension API is read + play-from-here only (no reorder/remove).
@MainActor
public struct QueueView: View {
    public init() {}
    @Environment(RoonClient.self) private var client
    @State private var showSaveSheet = false
    @State private var newPlaylistName = ""
    @State private var similarSeed: SonicSeed?

    public var body: some View {
        Group {
            if client.selectedZone == nil {
                ContentUnavailableView(LS("queue.noZoneTitle"), systemImage: "list.number",
                    description: LT("queue.noZoneDescription"))
            } else if client.queueItems.isEmpty {
                ContentUnavailableView(LS("queue.emptyTitle"), systemImage: "list.number",
                    description: LT("Niets in de wachtrij van \(client.selectedZone?.displayName ?? "deze zone")."))
            } else {
                List {
                    Section {
                        Text(queueSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(Array(client.queueItems.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 10) {
                            AlbumArtView(imageKey: item.imageKey, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .lineLimit(1)
                                    .fontWeight(index == 0 ? .semibold : .regular)
                                if let s = item.subtitle {
                                    Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            if index == 0 {
                                Image(systemName: "speaker.wave.2.fill")
                                    .font(.caption).foregroundStyle(Color.roonGold)
                            } else if item.length > 0 {
                                Text(formatTime(item.length))
                                    .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { playFromHere(item) }
                        .contextMenu {
                            Button(LS("queue.sonicallySimilar"), systemImage: "waveform.path.ecg") {
                                similarSeed = SonicSeed(title: item.title, artist: item.subtitle,
                                                        album: nil, imageKey: item.imageKey)
                            }
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel(queueLabel(item, isNowPlaying: index == 0))
                        .accessibilityHint(LS("queue.playFromHereHint"))
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(LS("nav.queue"))
        .similarTracksSheet(item: $similarSeed)
        .toolbar { if client.selectedZone != nil { queueOptions } }
        .onAppear(perform: restart)
        .onChange(of: client.selectedZone?.id) { _, _ in restart() }
        .onDisappear { client.stopQueue() }
        .alert(LS("queue.saveAsPlaylist"), isPresented: $showSaveSheet) {
            TextField(LS("queue.playlistNamePlaceholder"), text: $newPlaylistName)
            Button(LS("queue.cancel"), role: .cancel) {}
            Button(LS("queue.save")) {
                let name = newPlaylistName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                client.savePlaylist(name: name, tracks: queueRecords())
                newPlaylistName = ""
            }
        } message: {
            LT("Bewaar de \(client.queueItems.count) tracks in de wachtrij als playlist. Afspelen zoekt ze later op titel + artiest terug in je bibliotheek.")
        }
    }

    /// "23 nummers · 1 u 42 m" — the queue's footprint at a glance.
    private var queueSummary: String {
        let items = client.queueItems
        let total = items.reduce(0) { $0 + max(0, $1.length) }
        let noun = items.count == 1 ? "nummer" : "nummers"
        guard total > 0 else { return "\(items.count) \(noun)" }
        let h = total / 3600, m = (total % 3600) / 60
        let duration = h > 0 ? "\(h) u \(m) m" : "\(m) m"
        return "\(items.count) \(noun) · \(duration)"
    }

    /// Queue items as denormalized track records (the saved-playlist format:
    /// playback re-resolves by title + artist against the current cache).
    private func queueRecords() -> [TrackRecord] {
        client.queueItems.map { item in
            TrackRecord(id: "queue-\(item.id)", title: item.title,
                        artist: item.subtitle, imageKey: item.imageKey)
        }
    }

    /// Shuffle + repeat for the selected zone, reflecting the live Roon state.
    @ToolbarContentBuilder
    private var queueOptions: some ToolbarContent {
        if let zone = client.selectedZone {
            let shuffleOn = zone.shuffle ?? false
            let loop = zone.loopMode ?? "disabled"
            ToolbarItemGroup(placement: .primaryAction) {
                Button {
                    showSaveSheet = true
                } label: {
                    Image(systemName: "plus.rectangle.on.folder")
                }
                .disabled(client.queueItems.isEmpty)
                .accessibilityLabel(LS("queue.saveAsPlaylist"))
                .help(LS("queue.saveQueueHelp"))

                Button {
                    Haptics.tap()
                    Task { await client.setShuffle(zoneID: zone.id, enabled: !shuffleOn) }
                } label: {
                    Image(systemName: "shuffle")
                        .foregroundStyle(shuffleOn ? Color.roonGold : .secondary)
                }
                .accessibilityLabel(LS("queue.shuffle"))
                .help(shuffleOn ? LS("queue.shuffleOn") : LS("queue.shuffleOff"))

                Button {
                    Haptics.tap()
                    Task { await client.setRepeat(zoneID: zone.id, mode: NowPlayingHeroOptions.nextLoop(loop)) }
                } label: {
                    Image(systemName: loop == "loop_one" ? "repeat.1" : "repeat")
                        .foregroundStyle(loop == "disabled" ? .secondary : Color.roonGold)
                }
                .accessibilityLabel(NowPlayingHeroOptions.loopLabel(loop))
                .help(NowPlayingHeroOptions.loopLabel(loop))
            }
        }
    }

    private func restart() {
        if let zone = client.selectedZone?.id { client.startQueue(zoneID: zone) }
    }

    private func playFromHere(_ item: RoonClient.QueueItem) {
        guard let zone = client.selectedZone?.id else { return }
        Haptics.tap()
        Task { await client.playFromHere(zoneID: zone, queueItemID: item.id) }
    }

    private func queueLabel(_ item: RoonClient.QueueItem, isNowPlaying: Bool) -> String {
        var parts: [String] = []
        if isNowPlaying { parts.append(LS("queue.nowPlaying")) }
        parts.append(item.title)
        if let s = item.subtitle { parts.append(s) }
        return parts.joined(separator: ", ")
    }

    private func formatTime(_ seconds: Int) -> String {
        String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
