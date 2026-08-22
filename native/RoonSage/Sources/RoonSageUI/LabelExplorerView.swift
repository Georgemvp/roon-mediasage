import RoonSageCore
import SwiftUI

/// Browse the library by record label: a label-of-the-week feature, the full
/// label list (sortable), each label's releases, and merge/undo for cleaning up
/// messy label names. Labels are seeded from the dataset-imported label column;
/// external enrichment (tags/MusicBrainz/Discogs + logos) is a follow-up.
@MainActor
public struct LabelExplorerView: View {
    public init() {}
    @Environment(RoonClient.self) private var client

    @State private var labels: [DatabaseManager.LabelRow] = []
    @State private var labelOfWeek: DatabaseManager.LabelRow?
    @State private var sort: LabelSort = .albumCount
    @State private var loaded = false
    @State private var mergeSource: DatabaseManager.LabelRow?     // → target picker sheet
    @State private var lastMergedFrom: Int64?                     // → undo affordance

    public var body: some View {
        List {
            if let week = labelOfWeek {
                Section(LS("labelExplorer.labelOfWeek")) {
                    NavigationLink(value: week) { labelOfWeekCard(week) }
                }
            }
            Section {
                Picker(LS("labelExplorer.sort"), selection: $sort) {
                    LT("labelExplorer.mostAlbums").tag(LabelSort.albumCount)
                    LT("labelExplorer.name").tag(LabelSort.name)
                }
                .pickerStyle(.segmented)
            }
            Section(String(format: LS("labelExplorer.labelsSection"), labels.count)) {
                ForEach(labels) { label in
                    NavigationLink(value: label) { labelRow(label) }
                        .contextMenu {
                            Button { mergeSource = label } label: {
                                Label(LS("labelExplorer.mergeWith"), systemImage: "arrow.triangle.merge")
                            }
                        }
                }
            }
        }
        .navigationTitle(LS("labelExplorer.labels"))
        .navigationDestination(for: DatabaseManager.LabelRow.self) { LabelAlbumsView(label: $0) }
        .toolbar {
            if lastMergedFrom != nil {
                ToolbarItem {
                    Button {
                        Task { await undoLastMerge() }
                    } label: { Label(LS("labelExplorer.undo"), systemImage: "arrow.uturn.backward") }
                }
            }
        }
        .sheet(item: $mergeSource) { source in
            mergeTargetPicker(source)
        }
        .overlay {
            if loaded && labels.isEmpty { emptyState }
        }
        .task { await load() }
        .onChange(of: sort) { _, _ in Task { labels = await client.labels(sortedBy: sort) } }
    }

    // MARK: - Rows

    private func labelRow(_ label: DatabaseManager.LabelRow) -> some View {
        HStack(spacing: Spacing.md) {
            labelGlyph(label)
            VStack(alignment: .leading, spacing: 2) {
                Text(label.name).font(.body).lineLimit(1)
                Text("\(label.albumCount) album\(label.albumCount == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func labelOfWeekCard(_ label: DatabaseManager.LabelRow) -> some View {
        HStack(spacing: Spacing.md) {
            labelGlyph(label, size: 52)
            VStack(alignment: .leading, spacing: 4) {
                Text(label.name).font(.headline).lineLimit(2)
                Text(String(format: LS("labelExplorer.albumsInLibrary"), label.albumCount))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, Spacing.xs)
    }

    private func labelGlyph(_ label: DatabaseManager.LabelRow, size: CGFloat = 40) -> some View {
        Group {
            if let logo = label.logoURL, let url = URL(string: logo) {
                CachedArtImage(url: url) { placeholderGlyph(size) }
            } else {
                placeholderGlyph(size)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
    }

    private func placeholderGlyph(_ size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: Radius.md)
            .fill(Color.roonGold.opacity(0.15))
            .overlay(Image(systemName: "tag.fill").font(.system(size: size * 0.4)).foregroundStyle(Color.roonGold))
    }

    private var emptyState: some View {
        ContentUnavailableView(
            LS("labelExplorer.noLabelsTitle"),
            systemImage: "tag",
            description: LT("labelExplorer.noLabelsDescription")
        )
    }

    // MARK: - Merge target picker

    private func mergeTargetPicker(_ source: DatabaseManager.LabelRow) -> some View {
        NavigationStack {
            List(labels.filter { $0.id != source.id }) { target in
                Button {
                    Task { await merge(from: source, into: target) }
                } label: {
                    labelRow(target)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle(LS("labelExplorer.mergeNavTitle"))
            .toolbar {
                Button(LS("labelExplorer.cancel"), role: .cancel) { mergeSource = nil }
            }
        }
    }

    // MARK: - Actions

    private func load() async {
        _ = await client.ensureLabelsBuilt()
        labels = await client.labels(sortedBy: sort)
        labelOfWeek = await client.labelOfTheWeek()
        loaded = true
    }

    private func merge(from source: DatabaseManager.LabelRow, into target: DatabaseManager.LabelRow) async {
        mergeSource = nil
        await client.mergeLabels(from: source.id, into: target.id)
        lastMergedFrom = source.id
        await reload()
    }

    private func undoLastMerge() async {
        guard let from = lastMergedFrom else { return }
        await client.undoLabelMerge(from: from)
        lastMergedFrom = nil
        await reload()
    }

    private func reload() async {
        labels = await client.labels(sortedBy: sort)
        labelOfWeek = await client.labelOfTheWeek()
    }
}

// MARK: - One label's releases

@MainActor
struct LabelAlbumsView: View {
    @Environment(RoonClient.self) private var client
    let label: DatabaseManager.LabelRow
    @State private var albums: [DatabaseManager.AlbumResult] = []
    @State private var loaded = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: Spacing.lg)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Spacing.lg) {
                ForEach(albums) { album in
                    NavigationLink(value: album) { AlbumGridCell(album: album) }
                        .buttonStyle(.plain)
                }
            }
            .padding(Spacing.lg)
        }
        .navigationTitle(label.name)
        .navigationDestination(for: DatabaseManager.AlbumResult.self) { AlbumDetailView(album: $0) }
        .overlay { if loaded && albums.isEmpty { ProgressView() } }
        .task {
            albums = await client.albumsForLabel(label.id)
            loaded = true
        }
    }
}
