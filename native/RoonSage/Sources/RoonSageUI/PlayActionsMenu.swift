import RoonSageCore
import SwiftUI

/// The uniform play-action vocabulary (LMS-style): every playable entity —
/// track, album, artist, selection — offers the same four verbs plus
/// listen-on-this-device, in the same order, from one component. Embed inside
/// a `contextMenu` (or `Menu`); the entity's tracks are fetched lazily so a
/// grid of hundreds of cells costs nothing until the user actually opens one.
@MainActor
struct PlayActionsMenu: View {
    @Environment(RoonClient.self) private var client
    /// Lazily resolves the entity's tracks in play order.
    let fetch: () async -> [TrackRecord]
    /// Show the "Speel op dit apparaat" (local playback) entry.
    var includeLocal: Bool = true
    /// When set (single-track contexts), offer "Radio op dit nummer" — an
    /// endless sonic station seeded on exactly this track (song radio).
    var trackRadioSeed: TrackRecord? = nil

    var body: some View {
        // Every play AND queue verb follows the active output — the selected Roon
        // zone, or this device when "dit apparaat" is chosen. The queue verbs used
        // to be Roon-only because the local engine had no insert-next; it has one
        // now (`LocalPlaybackController.enqueue`), so they route like the rest.
        let hasOutput = client.hasActiveOutput
        Button(LS("bm.playNow"), systemImage: "play.fill") {
            runOutput { await client.playToActiveOutput($0) }
        }.disabled(!hasOutput)
        Button(LS("playActionsMenu.playNext"), systemImage: "text.line.first.and.arrowtriangle.forward") {
            runOutput { await client.queueToActiveOutput($0, next: true) }
        }.disabled(!hasOutput)
        Button(LS("playActionsMenu.queueLast"), systemImage: "text.append") {
            runOutput { await client.queueToActiveOutput($0, next: false) }
        }.disabled(!hasOutput)
        Button(LS("playActionsMenu.playShuffled"), systemImage: "shuffle") {
            runOutput { await client.playToActiveOutput($0.shuffled()) }
        }.disabled(!hasOutput)
        if let seed = trackRadioSeed {
            Divider()
            Button(LS("playActionsMenu.radioOnTrack"), systemImage: "dot.radiowaves.left.and.right") {
                Haptics.tap()
                Task {
                    await client.startTrackRadio(title: seed.title, artist: seed.artist,
                                                 album: seed.album)
                }
            }.disabled(!hasOutput)
            Menu(LS("playActionsMenu.startAsDJ"), systemImage: "person.wave.2") {
                ForEach(DJMode.allCases, id: \.self) { mode in
                    Button(mode.title) {
                        Haptics.tap()
                        Task {
                            await client.startTrackRadio(title: seed.title, artist: seed.artist,
                                                         album: seed.album, djMode: mode)
                        }
                    }
                }
            }.disabled(!hasOutput)
        }
        // "Take this with me" — the one verb that turns a streamer into a
        // portable player. Sits with the play verbs because that is where you
        // already are when you decide you want something.
        Divider()
        // For a single track we know whether it's already here, so the menu says
        // the true thing and offers the way back. It used to read "Bewaar op dit
        // apparaat" on a track that was already downloaded, with no way to remove
        // it except the separate downloads screen — a menu that lies about state
        // and then dead-ends.
        //
        // For an album or a selection this stays "bewaar": `fetch()` is
        // deliberately lazy (a grid of hundreds of cells must cost nothing until
        // you open one), so asking "is all of this here?" would mean resolving
        // every entity's tracks just to draw a context menu.
        if let seed = trackRadioSeed, client.isDownloaded(seed) {
            Button(LS("downloads.removeFromDevice"), systemImage: "arrow.down.circle.fill", role: .destructive) {
                Haptics.tap()
                Task { await client.removeOfflineTrack(matchKey: LocalPlayability.matchKey(for: seed)) }
            }
        } else {
            Button(LS("downloads.saveOnDevice"), systemImage: "arrow.down.circle") {
                Haptics.tap()
                Task {
                    let records = await fetch()
                    guard !records.isEmpty else { return }
                    await client.downloadForOffline(records)
                }
            }
            .disabled(client.downloadProgress != nil)
        }

        if includeLocal {
            Divider()
            Button(LS("playActionsMenu.playOnThisDevice"), systemImage: "iphone") {
                Haptics.tap()
                Task {
                    let records = await fetch()
                    guard !records.isEmpty else { return }
                    await client.playLocally(records)
                }
            }
        }
    }

    /// Fetch the entity's tracks, then hand them to an output-agnostic action —
    /// the action itself decides where they go (zone or this device) via
    /// `client.playToActiveOutput` / `client.queueToActiveOutput`.
    private func runOutput(_ action: @escaping (_ records: [TrackRecord]) async -> Void) {
        Haptics.tap()
        Task {
            let records = await fetch()
            guard !records.isEmpty else { return }
            await action(records)
        }
    }
}

extension DatabaseManager.LibraryTrackRow {
    /// The play/queue record for this library row.
    var asTrackRecord: TrackRecord {
        TrackRecord(id: id, title: title, artist: artist, album: album,
                    year: year, isLive: isLive, imageKey: imageKey)
    }
}
