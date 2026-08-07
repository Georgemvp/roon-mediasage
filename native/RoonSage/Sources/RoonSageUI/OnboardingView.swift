import SwiftUI
import RoonSageCore

/// First-run welcome shown to brand-new users *before* the connect screen.
///
/// Gating (see `WelcomeGate` in RootView): it appears whenever the app has
/// never successfully connected to a Roon Core (`client.savedHost == nil`) — so
/// it keeps showing on each launch *until the user is actually connected*, then
/// never nags a returning user again. The final step hands off to `ConnectView`.
///
/// Goals: explain what RoonSage is, make clear that the full experience needs
/// the **Analyzer/server** running on an always-on Mac, and preview the headline
/// features — all in Dutch, matching the rest of the app.
@MainActor
struct OnboardingView: View {
    /// Called when the user is ready to connect (taps "Verbinden" or "Overslaan").
    let onContinue: () -> Void

    @State private var step = 0

    private let steps = OnboardingStep.all

    var body: some View {
        VStack(spacing: 0) {
            // Skip — for users who already know RoonSage and just want to connect.
            HStack {
                Spacer()
                if step < steps.count - 1 {
                    Button(LS("onboarding.skip")) { onContinue() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .font(.callout)
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.top, Spacing.lg)
            .frame(height: 44)

            // Current step
            ScrollView {
                stepContent(steps[step])
                    .padding(.horizontal, Spacing.xl)
                    .padding(.top, Spacing.lg)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
            }
            .id(step) // restart entrance animation per step

            Spacer(minLength: 0)

            // Page dots
            HStack(spacing: 8) {
                ForEach(steps.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == step ? Color.roonGold : Color.secondary.opacity(0.3))
                        .frame(width: i == step ? 22 : 8, height: 8)
                        .animation(Motion.quick, value: step)
                }
            }
            .padding(.bottom, Spacing.lg)
            .accessibilityHidden(true)

            // Navigation
            HStack(spacing: Spacing.md) {
                if step > 0 {
                    Button {
                        withAnimation(Motion.standard) { step -= 1 }
                    } label: {
                        Label(LS("onboarding.back"), systemImage: "chevron.left").frame(minWidth: 120)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }

                if step < steps.count - 1 {
                    Button {
                        withAnimation(Motion.standard) { step += 1 }
                    } label: {
                        HStack(spacing: 6) {
                            LT("onboarding.next")
                            Image(systemName: "chevron.right")
                        }
                        .frame(minWidth: 160)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                } else {
                    Button { onContinue() } label: {
                        Label(LS("onboarding.connect"), systemImage: "music.note.house.fill").frame(minWidth: 200)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
            }
            .padding(.horizontal, Spacing.xl)
            .padding(.bottom, Spacing.xxl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Step content

    @ViewBuilder
    private func stepContent(_ s: OnboardingStep) -> some View {
        VStack(spacing: Spacing.xl) {
            VStack(spacing: Spacing.lg) {
                Image(systemName: s.icon)
                    .font(.system(size: 60))
                    .foregroundStyle(Color.roonGold)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)

                Text(s.title)
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)

                Text(s.subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            switch s.kind {
            case .intro:
                introBody
            case .server:
                serverBody
            case .features:
                featuresBody
            case .connect:
                connectBody
            }
        }
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }

    // Step 1 — what RoonSage is
    private var introBody: some View {
        VStack(spacing: Spacing.md) {
            LT("onboarding.introBody1")
            LT("onboarding.introBody2")
        }
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }

    // Step 2 — the Analyzer/server requirement (the part the user emphasised)
    private var serverBody: some View {
        VStack(spacing: Spacing.lg) {
            LT("onboarding.serverIntro")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            VStack(alignment: .leading, spacing: Spacing.md) {
                OnboardingBullet(icon: "waveform", title: LS("onboarding.bulletAudioTitle"),
                                 text: LS("onboarding.bulletAudioText"))
                OnboardingBullet(icon: "arrow.triangle.2.circlepath", title: LS("onboarding.bulletSyncTitle"),
                                 text: LS("onboarding.bulletSyncText"))
                OnboardingBullet(icon: "gearshape.2", title: LS("onboarding.bulletSettingsTitle"),
                                 text: LS("onboarding.bulletSettingsText"))
            }

            LT("onboarding.serverFootnote")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
    }

    // Step 3 — feature highlights
    private var featuresBody: some View {
        VStack(spacing: Spacing.md) {
            OnboardingBullet(icon: "wand.and.stars", title: LS("onboarding.featPlaylistsTitle"),
                             text: LS("onboarding.featPlaylistsText"))
            OnboardingBullet(icon: "waveform.path.ecg", title: "Sonic DNA & Music Map",
                             text: LS("onboarding.featDnaText"))
            OnboardingBullet(icon: "slider.horizontal.3", title: "DJ Set & Live DJ",
                             text: LS("onboarding.featDjText"))
            OnboardingBullet(icon: "sparkles", title: LS("onboarding.featDiscoverTitle"),
                             text: LS("onboarding.featDiscoverText"))
        }
    }

    // Step 4 — how to connect
    private var connectBody: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            OnboardingStepRow(number: 1, text: "onboarding.connectStep1")
            OnboardingStepRow(number: 2, text: "onboarding.connectStep2")
            OnboardingStepRow(number: 3, text: "onboarding.connectStep3")
        }
        .padding(Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: Radius.lg))
    }
}

// MARK: - Step model

private struct OnboardingStep: Identifiable {
    enum Kind { case intro, server, features, connect }
    let id = UUID()
    let kind: Kind
    let icon: String
    let title: String
    let subtitle: String

    static let all: [OnboardingStep] = [
        .init(kind: .intro, icon: "music.note.house.fill",
              title: LS("onboarding.stepIntroTitle"),
              subtitle: LS("onboarding.stepIntroSubtitle")),
        .init(kind: .server, icon: "server.rack",
              title: LS("onboarding.stepServerTitle"),
              subtitle: LS("onboarding.stepServerSubtitle")),
        .init(kind: .features, icon: "sparkles",
              title: LS("onboarding.stepFeaturesTitle"),
              subtitle: LS("onboarding.stepFeaturesSubtitle")),
        .init(kind: .connect, icon: "link",
              title: LS("onboarding.stepConnectTitle"),
              subtitle: LS("onboarding.stepConnectSubtitle")),
    ]
}

// MARK: - Reusable rows

private struct OnboardingBullet: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Color.roonGold)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct OnboardingStepRow: View {
    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            Text("\(number)")
                .font(.callout.weight(.bold))
                .foregroundStyle(Color.roonGold)
                .frame(width: 26, height: 26)
                .background(Color.roonGold.opacity(0.15), in: Circle())
                .accessibilityHidden(true)
            LT(text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
