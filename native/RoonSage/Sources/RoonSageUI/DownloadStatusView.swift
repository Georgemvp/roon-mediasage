import RoonSageCore
import SwiftUI

/// The download state of a track, in the three places a list can be: waiting in
/// the queue, coming down now, already here.
///
/// One definition, used by both the track row and the album header, because a
/// downloading track that shows a spinner in one list and a static arrow in the
/// other reads as two different things happening.
///
/// **Why `client.downloadProgress` is read but not used.** The queue itself
/// (`OfflineDownloadManager`) is a plain class behind a lock, not `@Observable`
/// — it has to be, since its callbacks arrive on URLSession's own queue. So
/// nothing here would ever re-render as bytes arrive. `downloadProgress` IS
/// observable and ticks on every progress callback, so touching it establishes
/// the dependency that makes the mark live.
@MainActor
struct DownloadStatusMark: View {
    @Environment(RoonClient.self) private var client
    let track: TrackRecord

    /// Reading `downloadProgress` here — not in `body` — keeps the dependency
    /// out of a `ViewBuilder`, where the only way to evaluate an expression is
    /// the `let _ =` form. Called from `body`, so the observation is registered
    /// all the same.
    private var liveStatus: OfflineDownloadManager.Status? {
        _ = client.downloadProgress
        return client.downloadStatus(for: track)
    }

    var body: some View {
        switch liveStatus {
        case .downloading(let fraction):
            ProgressView(value: max(0.02, fraction))
                .progressViewStyle(.circular)
                .controlSize(.mini)
                .accessibilityLabel(LS("downloads.statusDownloading"))
        case .queued:
            Image(systemName: "arrow.down.circle")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .accessibilityLabel(LS("downloads.statusQueued"))
        case .done, .none:
            if client.isDownloaded(track) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.roonGold)
                    .accessibilityLabel(LS("downloads.availableOffline"))
            }
        }
    }
}

/// The album header's "take this with you" control.
///
/// Three states rather than a menu item that gives no feedback: nothing pinned
/// (an outline arrow you can tap), some or all of it in flight (a progress
/// ring), everything here (a filled gold arrow, and tapping does nothing —
/// removal lives on the Downloads screen, where it can say what it deletes).
@MainActor
struct AlbumDownloadButton: View {
    @Environment(RoonClient.self) private var client
    let tracks: [DatabaseManager.LibraryTrackRow]

    private var records: [TrackRecord] { tracks.map(\.asTrackRecord) }

    /// Fraction of the album that is on the device. Computed over the album's
    /// own rows, so "gedownload" means this album, not the library.
    private var downloadedCount: Int {
        records.filter { client.isDownloaded($0) }.count
    }

    /// Same trick as `DownloadStatusMark.liveStatus`: touch the observable
    /// progress outside the `ViewBuilder` so the ring animates as bytes arrive.
    private var inFlight: Bool {
        _ = client.downloadProgress
        return records.contains { client.downloadStatus(for: $0) != nil }
    }

    var body: some View {
        let done = downloadedCount
        let complete = !records.isEmpty && done == records.count
        Button {
            Haptics.tap()
            Task { await client.downloadForOffline(records) }
        } label: {
            if inFlight {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: complete ? "arrow.down.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(complete ? Color.roonGold : Color.primary)
            }
        }
        .buttonStyle(.bordered)
        .disabled(tracks.isEmpty || complete || inFlight)
        .accessibilityLabel(complete ? LS("downloads.availableOffline") : LS("downloads.saveOnDevice"))
        .help(complete ? LS("downloads.availableOffline") : LS("downloads.saveOnDevice"))
    }
}
