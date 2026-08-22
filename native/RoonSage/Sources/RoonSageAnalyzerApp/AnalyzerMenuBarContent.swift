import AppKit
import RoonSageCore
import RoonSageUI
import SwiftUI

/// Modern, comprehensive MenuBar popup for RoonSage Server 2.0.
/// Displays live health telemetry, active background worker progress,
/// streaming server status, and quick server management actions.
@MainActor
struct AnalyzerMenuBarContent: View {
    @Environment(AnalyzerModel.self) private var model
    @Environment(RoonClient.self) private var client
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerBar

            Divider()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    servicesStatusGrid
                    backgroundWorkersSection
                    nowPlayingOrNetworkStatus
                }
                .padding(Spacing.md)
            }
            .frame(maxHeight: 460)

            Divider()

            footerActions
        }
        .frame(width: 350)
        .background(Color.platformCardBackground)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: Spacing.sm) {
            ZStack {
                Circle()
                    .fill(Color.roonGold.opacity(0.18))
                    .frame(width: 32, height: 32)
                Image(systemName: "waveform.path.badge.plus")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.roonGold)
            }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: Spacing.xs) {
                    Text("RoonSage Server")
                        .font(.headline)
                    Text("2.0")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.roonGold.opacity(0.2), in: Capsule())
                        .foregroundStyle(Color.roonGold)
                }
                Text("Always-on audio-analyse & feature server")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            serverHealthBadge
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }

    private var serverHealthBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(overallStatusColor)
                .frame(width: 8, height: 8)
            Text(overallStatusText)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(overallStatusColor)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(overallStatusColor.opacity(0.12), in: Capsule())
    }

    private var overallStatusColor: Color {
        if model.isAnalyzing { return .blue }
        if client.connectionState.isConnected && model.isServing { return .green }
        if client.connectionState.isBusy { return .orange }
        return .secondary
    }

    private var overallStatusText: String {
        if model.isAnalyzing { return "Analyseren" }
        if client.connectionState.isConnected && model.isServing { return "Actief" }
        if client.connectionState.isBusy { return "Verbinden" }
        return "Gereed"
    }

    // MARK: - Services Status Grid

    private var servicesStatusGrid: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("KERN SERVICES")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
                .tracking(0.5)

            HStack(spacing: Spacing.sm) {
                // Roon Core Card
                ServiceMiniCard(
                    icon: "link",
                    title: "Roon Core",
                    subtitle: client.connectionState.isConnected
                        ? (client.coreHost ?? "Verbonden")
                        : client.connectionState.label,
                    statusDot: client.connectionState.isConnected ? .green : .orange
                )

                // Feature Server Card
                ServiceMiniCard(
                    icon: "dot.radiowaves.left.and.right",
                    title: "Feature API",
                    subtitle: model.isServing ? "Poort \(model.port)" : "Inactief",
                    statusDot: model.isServing ? .green : .secondary
                )
            }
        }
    }

    // MARK: - Background Workers Monitor

    private var backgroundWorkersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ACHTERGROND PROCESSEN")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)
                Spacer()
                if model.isAnalyzing {
                    Text("Actief")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.blue)
                }
            }

            VStack(spacing: 6) {
                // 1. Audio Analyse & Essentia DSP
                analysisWorkerRow

                // 2. MusicBrainz Genres
                workerRow(
                    icon: "music.quarternote.3",
                    title: "MusicBrainz Genres",
                    countText: "\(model.mbEnrichedCount) verrijkt",
                    isActive: model.isEnriching,
                    isEnabled: model.autoEnrich
                )

                // 3. Deezer Populariteit
                workerRow(
                    icon: "chart.line.uptrend.xyaxis",
                    title: "Deezer Populariteit",
                    countText: "\(model.popularityCount) getagd",
                    isActive: model.isPopularityEnriching,
                    isEnabled: model.autoPopularity
                )

                // 4. Dynamic Range / F3 Loudness
                workerRow(
                    icon: "waveform",
                    title: "Loudness & DR (F3)",
                    countText: "\(model.loudnessCount) berekend",
                    isActive: model.isLoudnessBackfilling,
                    isEnabled: model.autoLoudness
                )

                // 5. Qobuz Previews & Embeddings
                workerRow(
                    icon: "sparkles",
                    title: "Qobuz Previews",
                    countText: "\(model.previewCount) embeddings",
                    isActive: model.isPreviewBackfilling,
                    isEnabled: model.autoPreview
                )

                // 6. Deezer Genres
                workerRow(
                    icon: "tag",
                    title: "Deezer Genres",
                    countText: "\(model.deezerGenreCount) profielen",
                    isActive: model.isDeezerGenreEnriching,
                    isEnabled: model.autoDeezerGenre
                )
            }
            .padding(Spacing.sm)
            .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.md))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.md)
                    .strokeBorder(Color.secondary.opacity(0.1))
            )
        }
    }

    // MARK: - Analysis Worker Row with Progress

    private var analysisWorkerRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "waveform.path.ecg")
                    .font(.caption)
                    .foregroundStyle(model.isAnalyzing ? Color.blue : Color.secondary)
                    .frame(width: 16)

                Text("Audio Analyse")
                    .font(.caption.weight(.medium))

                Spacer()

                if model.isAnalyzing, let p = model.analyze, p.total > 0 {
                    Text("\(p.done + p.failed)/\(p.total)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("\(model.trackCount) tracks")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Button {
                    if model.isAnalyzing {
                        model.cancelAnalyze()
                    } else {
                        model.startAnalyze()
                    }
                } label: {
                    Image(systemName: model.isAnalyzing ? "pause.circle.fill" : "play.circle.fill")
                        .font(.callout)
                        .foregroundStyle(model.isAnalyzing ? Color.orange : Color.blue)
                }
                .buttonStyle(.plain)
                .help(model.isAnalyzing ? "Pauzeer analyse" : "Start analyse")
            }

            if model.isAnalyzing, let p = model.analyze, p.total > 0 {
                ProgressView(value: Double(p.done + p.failed), total: Double(p.total))
                    .progressViewStyle(.linear)
                    .tint(.blue)
                    .padding(.top, 2)
            }
        }
    }

    private func workerRow(
        icon: String,
        title: String,
        countText: String,
        isActive: Bool,
        isEnabled: Bool
    ) -> some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: icon)
                .font(.caption2)
                .foregroundStyle(isActive ? Color.roonGold : (isEnabled ? Color.secondary : Color.secondary.opacity(0.5)))
                .frame(width: 16)

            Text(title)
                .font(.caption)
                .foregroundStyle(isEnabled ? Color.primary : Color.secondary)

            Spacer()

            if isActive {
                ProgressView()
                    .controlSize(.mini)
                    .padding(.trailing, 2)
            }

            Text(countText)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    // MARK: - Now Playing / Live State

    @ViewBuilder
    private var nowPlayingOrNetworkStatus: some View {
        if let np = client.activeNowPlaying, !np.title.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("NU AAN HET AFSPELEN")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .tracking(0.5)

                HStack(spacing: Spacing.sm) {
                    Image(systemName: "music.note")
                        .font(.title3)
                        .foregroundStyle(Color.roonGold)
                        .frame(width: 28, height: 28)
                        .background(Color.roonGold.opacity(0.15), in: RoundedRectangle(cornerRadius: Radius.sm))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(np.title)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                        if let artist = np.artist, !artist.isEmpty {
                            Text(artist)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    if let zone = client.selectedZone {
                        Text(zone.displayName)
                            .font(.system(size: 9, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(Spacing.sm)
                .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.md))
            }
        }
    }

    // MARK: - Footer Actions

    private var footerActions: some View {
        VStack(spacing: 4) {
            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                HStack {
                    Image(systemName: "macwindow.on.rectangle")
                    Text("Dashboard Openen")
                        .fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.caption2)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(Color.roonGold.opacity(0.15), in: RoundedRectangle(cornerRadius: Radius.sm))
                .foregroundStyle(Color.roonGold)
            }
            .buttonStyle(.plain)

            HStack(spacing: Spacing.sm) {
                if !client.connectionState.isConnected {
                    Button("Opnieuw verbinden") {
                        reconnectRoon()
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }

                Spacer()

                Button("Afsluiten") {
                    NSApplication.shared.terminate(nil)
                }
                .font(.caption)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
        .padding(.horizontal, Spacing.md)
        .padding(.vertical, Spacing.sm)
    }

    private func reconnectRoon() {
        Task {
            await client.disconnect()
            if let host = client.savedHost {
                await client.connect(host: host, port: client.savedPort)
            } else {
                await client.discoverAndConnect()
            }
        }
    }
}

// MARK: - Service Mini Card Component

@MainActor
private struct ServiceMiniCard: View {
    let icon: String
    let title: String
    let subtitle: String
    let statusDot: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption.weight(.semibold))
                Spacer()
                Circle()
                    .fill(statusDot)
                    .frame(width: 6, height: 6)
            }

            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Spacing.sm)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.md)
                .strokeBorder(Color.secondary.opacity(0.1))
        )
    }
}
