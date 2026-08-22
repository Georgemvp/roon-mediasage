import RoonSageCore
import SwiftUI

/// The active output's play queue.
///
/// Two very different backends behind one screen: a Roon zone's queue is read +
/// play-from-here only (its extension API exposes nothing else), while the
/// on-device queue is an array this app owns — so when you're listening on this
/// device the same screen also reorders and removes.
@MainActor
public struct QueueView: View {
    public init() {}
    @Environment(RoonClient.self) private var client
    @State private var showSaveSheet = false
    @State private var newPlaylistName = ""
    @State private var similarSeed: SonicSeed?
    /// Set by the toolbar to ask the local queue's ScrollViewReader to jump to a
    /// row; cleared again once the scroll has been requested.
    @State private var scrollTarget: Int?

    public var body: some View {
        Group {
            if client.localOutputSelected {
                localQueue
            } else if client.selectedZone == nil {
                ContentUnavailableView(LS("queue.noZoneTitle"), systemImage: "list.number",
                    description: LT("queue.noZoneDescription"))
            } else if client.queueItems.isEmpty {
                ContentUnavailableView(LS("queue.emptyTitle"), systemImage: "list.number",
                    description: Text(String(format: LS("queue.emptyForZone"),
                                 client.selectedZone?.displayName ?? LS("queue.emptyForZoneFallback"))))
            } else {
                List {
                    Section {
                        Text(queueSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                    }
                    // The playing row is index 0 in Roon's queue, so "am I now
                    // playing" is `item.id == first.id` — no enumeration needed.
                    // `Array(...enumerated())` rebuilt a full tuple copy of the
                    // list on every body evaluation purely to learn that one bit;
                    // it is the same construction `LibraryView` was cleaned of.
                    let nowPlayingID = client.queueItems.first?.id
                    ForEach(client.queueItems) { item in
                        let isNowPlaying = item.id == nowPlayingID
                        HStack(spacing: 10) {
                            AlbumArtView(imageKey: item.imageKey, size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title)
                                    .lineLimit(1)
                                    .fontWeight(isNowPlaying ? .semibold : .regular)
                                if let s = item.subtitle {
                                    Text(s).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer()
                            if isNowPlaying {
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
                        .accessibilityLabel(queueLabel(item, isNowPlaying: isNowPlaying))
                        .accessibilityHint(LS("queue.playFromHereHint"))
                    }
                    // Say why this screen is poorer than the on-device one.
                    //
                    // The local queue reorders, removes and clears; a Roon zone
                    // does none of that, because the Extension API has no verb
                    // for it (`TransportService` exposes control, play-from-here,
                    // volume, mute, seek, shuffle and repeat — that is the whole
                    // list). Without a word here the difference reads as a bug in
                    // this app, and the player's own overflow menu even hinted
                    // that clearing was possible. An explained limit beats a
                    // missing button.
                    Section {
                        Text(LS("queue.zoneReadOnly"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(LS("nav.queue"))
        .similarTracksSheet(item: $similarSeed)
        .toolbar {
            if client.localOutputSelected { localQueueOptions }
            else if client.selectedZone != nil { queueOptions }
        }
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
            Text(String(format: LS("queue.saveBody"), savableCount))
        }
    }

    /// Tracks the save-as-playlist action would write, from whichever queue is
    /// on screen.
    private var savableCount: Int {
        client.localOutputSelected ? client.localPlayback.queue.count : client.queueItems.count
    }

    /// "23 nummers · 1 u 42 m" — the queue's footprint at a glance.
    ///
    /// Through the catalogue, plural included: this line was assembled from Dutch
    /// literals and so read "1 nummer" on an English phone, on the queue page of
    /// an otherwise English player.
    private var queueSummary: String {
        let items = client.queueItems
        let total = items.reduce(0) { $0 + max(0, $1.length) }
        let count = Self.trackCount(items.count)
        guard total > 0 else { return count }
        let h = total / 3600, m = (total % 3600) / 60
        let duration = h > 0 ? String(format: LS("queue.durationHM"), h, m)
                             : String(format: LS("queue.durationM"), m)
        return "\(count) · \(duration)"
    }

    /// "1 nummer" / "23 nummers", localised.
    static func trackCount(_ n: Int) -> String {
        // Two spelled-out calls, not `LS(n == 1 ? … : …)`: check-localization.sh
        // greps for `LS("literal")` and reads a key chosen inside the call as
        // used by nobody.
        if n == 1 { return String(format: LS("queue.trackCountOne"), n) }
        return String(format: LS("queue.trackCountMany"), n)
    }

    /// Queue items as denormalized track records (the saved-playlist format:
    /// playback re-resolves by title + artist against the current cache).
    private func queueRecords() -> [TrackRecord] {
        if client.localOutputSelected {
            return client.localPlayback.queue.map { track in
                TrackRecord(id: "local-\(track.id)", title: track.title,
                            artist: track.artist, album: track.album, imageKey: track.imageKey)
            }
        }
        return client.queueItems.map { item in
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

    // MARK: - On-device queue
    //
    // The local engine owns a plain array, so unlike the Roon path this one is
    // editable: swipe to remove, drag to reorder, tap to jump. The whole order is
    // shown (not just what's upcoming) with the playing track marked, so you can
    // see where you are in a long queue.

    private var localQueue: some View {
        let lp = client.localPlayback
        return Group {
            if lp.queue.isEmpty {
                ContentUnavailableView(LS("queue.localEmptyTitle"), systemImage: "list.number",
                    description: LT("queue.localEmptyDescription"))
            } else {
                // ScrollViewReader so "spring naar nu" can reach the playing row
                // in a queue of hundreds. The toolbar can't hold the proxy, so it
                // sets `scrollTarget` and the change is observed in here.
                ScrollViewReader { proxy in
                    List {
                        Section {
                            Text(localSummary)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .listRowSeparator(.hidden)
                        }
                        // Keyed on position, not on the track's id: a queue may
                        // legitimately hold the same song twice, and duplicate ids
                        // break List's diffing — and with it onMove/onDelete.
                        ForEach(Array(lp.queue.enumerated()), id: \.offset) { index, track in
                            localRow(track, index: index, playingAt: lp.index)
                                .id(index)
                        }
                        .onDelete { lp.removeFromQueue(atOffsets: $0) }
                        .onMove { lp.moveInQueue(fromOffsets: $0, toOffset: $1) }
                    }
                    .listStyle(.plain)
                    .onChange(of: scrollTarget) { _, target in
                        guard let target else { return }
                        withAnimation { proxy.scrollTo(target, anchor: .center) }
                        scrollTarget = nil
                    }
                }
            }
        }
    }

    private func localRow(_ track: LocalPlaybackController.Track,
                          index: Int, playingAt current: Int) -> some View {
        HStack(spacing: 10) {
            AlbumArtView(imageKey: track.imageKey, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .lineLimit(1)
                    .fontWeight(index == current ? .semibold : .regular)
                if !track.artist.isEmpty {
                    Text(track.artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            if index == current {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption).foregroundStyle(Color.roonGold)
            }
        }
        // Already-played tracks stay in the list but recede, so your position in
        // a long queue reads at a glance.
        .opacity(index < current ? 0.5 : 1)
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.tap()
            client.localPlayback.jump(to: index)
        }
        .contextMenu {
            Button(LS("queue.sonicallySimilar"), systemImage: "waveform.path.ecg") {
                similarSeed = SonicSeed(title: track.title, artist: track.artist,
                                        album: track.album, imageKey: track.imageKey)
            }
            Button(role: .destructive) {
                client.localPlayback.removeFromQueue(atOffsets: IndexSet(integer: index))
            } label: {
                Label(LS("queue.removeFromQueue"), systemImage: "minus.circle")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(localLabel(track, isNowPlaying: index == current))
        .accessibilityHint(LS("queue.playFromHereHint"))
    }

    /// "23 nummers · nog 12" — the local engine only learns a track's length once
    /// it loads, so there's no total duration to show; the remaining count is the
    /// useful number instead.
    private var localSummary: String {
        let lp = client.localPlayback
        let count = Self.trackCount(lp.queue.count)
        let remaining = max(0, lp.queue.count - lp.index - 1)
        guard remaining > 0 else { return count }
        return "\(count) · \(String(format: LS("queue.remaining"), remaining))"
    }

    /// Shuffle, repeat and save for the on-device queue — the same vocabulary as
    /// the zone toolbar, driven by the local engine. iOS additionally needs Edit
    /// mode before a List row can be dragged.
    @ToolbarContentBuilder
    private var localQueueOptions: some ToolbarContent {
        let lp = client.localPlayback
        ToolbarItemGroup(placement: .primaryAction) {
            #if os(iOS)
            EditButton().disabled(lp.queue.isEmpty)
            #endif
            Button {
                scrollTarget = lp.index
            } label: {
                Image(systemName: "scope")
            }
            .disabled(lp.queue.isEmpty)
            .accessibilityLabel(LS("queue.jumpToCurrent"))
            .help(LS("queue.jumpToCurrent"))

            Button {
                Haptics.tap()
                lp.clearUpcoming()
            } label: {
                Image(systemName: "text.badge.minus")
            }
            .disabled(lp.index + 1 >= lp.queue.count)
            .accessibilityLabel(LS("queue.clearUpcoming"))
            .help(LS("queue.clearUpcomingHelp"))

            Button {
                showSaveSheet = true
            } label: {
                Image(systemName: "plus.rectangle.on.folder")
            }
            .disabled(lp.queue.isEmpty)
            .accessibilityLabel(LS("queue.saveAsPlaylist"))
            .help(LS("queue.saveQueueHelp"))

            Button {
                Haptics.tap()
                lp.setShuffle(!lp.shuffle)
            } label: {
                Image(systemName: "shuffle")
                    .foregroundStyle(lp.shuffle ? Color.roonGold : .secondary)
            }
            .accessibilityLabel(LS("queue.shuffle"))
            .help(lp.shuffle ? LS("queue.shuffleOn") : LS("queue.shuffleOff"))

            Button {
                Haptics.tap()
                lp.setLoop(NowPlayingHeroOptions.nextLoop(lp.loopMode))
            } label: {
                Image(systemName: lp.loopMode == "loop_one" ? "repeat.1" : "repeat")
                    .foregroundStyle(lp.loopMode == "disabled" ? .secondary : Color.roonGold)
            }
            .accessibilityLabel(NowPlayingHeroOptions.loopLabel(lp.loopMode))
            .help(NowPlayingHeroOptions.loopLabel(lp.loopMode))
        }
    }

    private func localLabel(_ track: LocalPlaybackController.Track, isNowPlaying: Bool) -> String {
        var parts: [String] = []
        if isNowPlaying { parts.append(LS("queue.nowPlaying")) }
        parts.append(track.title)
        if !track.artist.isEmpty { parts.append(track.artist) }
        return parts.joined(separator: ", ")
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
