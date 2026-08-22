import SwiftUI

/// A title for a screen that is shown **both** on its own — pushed onto a stack,
/// or as a macOS sidebar destination — and as one segment inside a hub.
///
/// SwiftUI lets the *deepest* `navigationTitle` win, so a hub child that titles
/// itself silently renames the tab it is sitting in. That is how all four tabs
/// came to disagree with the tab bar directly beneath them: the Stations tab read
/// "Radio's" (from `SonicRadioView`), Ontdek read "Herontdek" (`DiscoveryView`),
/// Zoek read "Bibliotheek (15 tracks)" (`LibraryView`) — and the title changed
/// again with every flick of the segmented control, because the next segment's
/// child brought its own name along.
///
/// `.screenTitle(_:)` titles the screen only when it is standing on its own. A
/// hub wraps its content in `.hubContent()` and keeps the name the tab gave it.
private struct InsideHubKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var insideHub: Bool {
        get { self[InsideHubKey.self] }
        set { self[InsideHubKey.self] = newValue }
    }
}

private struct ScreenTitleModifier: ViewModifier {
    @Environment(\.insideHub) private var insideHub
    let title: String

    @ViewBuilder
    func body(content: Content) -> some View {
        if insideHub { content } else { content.navigationTitle(title) }
    }
}

extension View {
    /// Title this screen — unless it is a segment inside a hub, which is named by
    /// the tab that owns it.
    public func screenTitle(_ title: String) -> some View {
        modifier(ScreenTitleModifier(title: title))
    }

    /// Mark a subtree as hub content: the screens inside stop titling themselves.
    /// Deliberately *not* recursive-proof — a hub inside a hub would be the real
    /// bug, and this makes it show up as a missing title rather than hide it.
    public func hubContent() -> some View {
        environment(\.insideHub, true)
    }
}
