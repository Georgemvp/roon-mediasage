import RoonSageCore
import SwiftUI

/// The Plex sign-in, as a sheet any screen can summon.
///
/// Linking Plex is the answer to "my library is empty", and the empty state is
/// exactly where a user has no idea that Settings has a Plex section. So the
/// flow lives here, in one place, and both Settings and the empty state call it
/// through `client.requestPlexLink()`.
@MainActor
public struct PlexLinkSheet: View {
    @Environment(RoonClient.self) private var client
    @Environment(\.dismiss) private var dismiss

    @State private var code: String?
    @State private var busy = false
    @State private var error: String?

    public init() {}

    public var body: some View {
        VStack(spacing: Spacing.lg) {
            Image(systemName: "link")
                .font(.system(size: 44))
                .foregroundStyle(Color.roonGold)
                .accessibilityHidden(true)

            Text(LS("onboarding.plexLink")).font(.title2.bold())

            if let code {
                Text(code)
                    .font(.system(.largeTitle, design: .monospaced).weight(.bold))
                    .tracking(8)
                    .textSelection(.enabled)
                Text(LS("settings.plexCodeHelp"))
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                ProgressView()
            } else {
                Text(LS("onboarding.plexVsServer"))
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button {
                    start()
                } label: {
                    Label(LS("onboarding.plexLink"), systemImage: "link").frame(minWidth: 200)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(busy)
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(Spacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .presentationDetents([.medium])
    }

    private func start() {
        busy = true
        error = nil
        Task {
            defer { busy = false; code = nil }
            do {
                let token = try await PlexAuth.signIn { pin in
                    Task { @MainActor in code = pin.code }
                }
                if token != nil {
                    // Resolves the server address and kicks off the first import.
                    client.refreshPlexLinkState()
                    client.completeOnboarding()
                    dismiss()
                } else {
                    error = LS("onboarding.plexCodeExpired")
                }
            } catch {
                self.error = String(format: LS("onboarding.plexLinkFailed"), error.localizedDescription)
            }
        }
    }
}
