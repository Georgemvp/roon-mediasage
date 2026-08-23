import RoonSageCore
import SwiftUI

/// Shown in place of a feature that needs the RoonSage server.
///
/// Since the app can run on a Plex sign-in alone (user, 2026-08-23: *"de analyzer
/// is dus optioneel"*), a device may legitimately have no server. The features
/// that depend on one — anything driven by BPM, Camelot, CLAP vectors or a Roon
/// zone — must then say so and offer the way in, rather than render an empty
/// screen that reads as a bug.
///
/// Deliberately not an error: nothing is broken, this device simply has not been
/// connected to a server.
@MainActor
public struct AnalyzerRequiredNotice: View {
    private let feature: String
    private let reason: String
    @Environment(RoonClient.self) private var client

    /// - Parameters:
    ///   - feature: what the user was trying to open, e.g. "DJ-sets".
    ///   - reason: the one thing the server supplies that Plex cannot.
    public init(feature: String, reason: String) {
        self.feature = feature
        self.reason = reason
    }

    public var body: some View {
        VStack(spacing: Spacing.md) {
            Image(systemName: "waveform.badge.exclamationmark")
                .font(.system(size: 40))
                .foregroundStyle(Color.roonGold)
                .accessibilityHidden(true)
            Text("\(feature) heeft de RoonSage-server nodig")
                .font(.headline)
                .multilineTextAlignment(.center)
            Text(reason)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button {
                client.requestServerConnection()
            } label: {
                Label("Verbinden met de server", systemImage: "antenna.radiowaves.left.and.right")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension View {
    /// Replace this view with `AnalyzerRequiredNotice` when no server is configured.
    ///
    /// A modifier rather than an `if` inside each screen: the feature views stay
    /// unchanged and the gate is one line, so adding it somewhere new cannot
    /// accidentally re-indent or restructure the screen it guards.
    /// `@MainActor` because it reads `client.plexStandalone` and builds a
    /// main-actor view. A `View` extension is nonisolated by default, so without
    /// this the call is only legal by accident of the local toolchain — it built
    /// here and failed on CI with "main actor-isolated property 'plexStandalone'
    /// can not be referenced from a non-isolated context".
    @MainActor
    @ViewBuilder
    public func requiresAnalyzer(_ client: RoonClient, feature: String, reason: String) -> some View {
        if client.plexStandalone {
            AnalyzerRequiredNotice(feature: feature, reason: reason)
        } else {
            self
        }
    }
}
