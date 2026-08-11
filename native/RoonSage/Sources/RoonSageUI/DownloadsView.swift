import RoonSageCore
import SwiftUI

/// What you took with you.
///
/// Downloads shipped without anywhere to see them — the whole feature was a
/// number in Settings. A download you can't inspect, play or remove one by one
/// is half a feature, and worse, unverifiable: you couldn't tell whether the
/// album you asked for actually landed.
///
/// Deliberately plain: a list, play-all, swipe to remove. This is a management
/// screen, not another place to discover music.
@MainActor
public struct DownloadsView: View {
    public init() {}
    @Environment(RoonClient.self) private var client

    @State private var tracks: [DatabaseManager.OfflineTrack] = []
    @State private var loading = true

    private static let sizeFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useMB, .useGB]
        f.countStyle = .file
        return f
    }()

    public var body: some View {
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if tracks.isEmpty {
                ContentUnavailableView(LS("downloads.emptyTitle"), systemImage: "arrow.down.circle",
                                       description: LT("downloads.emptyDescription"))
            } else {
                List {
                    Section {
                        Text(summary)
                            .font(.caption).foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(tracks) { track in
                        row(track)
                    }
                    .onDelete { offsets in
                        let keys = offsets.map { tracks[$0].matchKey }
                        Task {
                            for key in keys { await client.removeOfflineTrack(matchKey: key) }
                            await load()
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle(LS("downloads.sectionTitle"))
        .toolbar {
            if !tracks.isEmpty {
                Button {
                    Haptics.tap()
                    Task { await client.playToActiveOutput(tracks.map(record)) }
                } label: { Image(systemName: "play.fill") }
                    .disabled(!client.hasActiveOutput)
                    .accessibilityLabel(LS("downloads.playAll"))
                    .help(LS("downloads.playAll"))
            }
        }
        .task { await load() }
    }

    private var summary: String {
        let bytes = tracks.reduce(0) { $0 + $1.bytes }
        let noun = tracks.count == 1 ? LS("downloads.trackSingular") : LS("downloads.trackPlural")
        return "\(tracks.count) \(noun) · \(Self.sizeFormatter.string(fromByteCount: Int64(bytes)))"
    }

    private func row(_ track: DatabaseManager.OfflineTrack) -> some View {
        HStack(spacing: 10) {
            AlbumArtView(imageKey: track.imageKey, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).lineLimit(1)
                if let artist = track.artist {
                    Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer()
            Text(Self.sizeFormatter.string(fromByteCount: Int64(track.bytes)))
                .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            Haptics.tap()
            Task { await client.playToActiveOutput([record(track)]) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }

    /// A downloaded row is identified by its match key, which is exactly what the
    /// player resolves against — so playing from here needs no library lookup.
    private func record(_ t: DatabaseManager.OfflineTrack) -> TrackRecord {
        TrackRecord(id: t.matchKey, title: t.title, artist: t.artist, album: t.album,
                    matchKey: t.matchKey, imageKey: t.imageKey)
    }

    private func load() async {
        tracks = (try? await client.database?.offlineTracks()) ?? []
        loading = false
    }
}
