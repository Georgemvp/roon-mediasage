#if os(macOS)
import AppKit

/// Put the cursor in the window's search field — what ⌘F does everywhere else.
///
/// The app had no ⌘F at all: the only global bindings were ⌘K (palette), ⌘1…9,
/// and the transport keys. On a Mac that is a reflex, and a music app with a
/// 100k-track library is exactly where you use it.
///
/// It has to go through AppKit. SwiftUI's own answer, `.searchFocused(_:)`,
/// is macOS 15 / iOS 18 and this package targets macOS 14 — and `.searchable`
/// exposes no other way to take focus. So: walk the key window for the
/// `NSSearchField` that `.searchable` installed and make it first responder.
/// `NSSearchField` is a concrete public class and `subviews` is public API, so
/// this is ordinary AppKit rather than a private-API trick; the one thing it
/// must never do is throw or hang if the layout changes, hence the plain
/// depth-limited walk and the silent `false` when nothing is found.
enum SearchFieldFocus {

    /// Focus the first search field in the key window. Returns whether it found one.
    @MainActor
    @discardableResult
    static func focusKeyWindowSearchField() -> Bool {
        guard let window = NSApp.keyWindow, let root = window.contentView else { return false }
        guard let field = firstSearchField(in: root, depth: 0) else { return false }
        window.makeFirstResponder(field)
        // Select what's there, so ⌘F on an existing query replaces it instead of
        // appending — the behaviour of every other Find field.
        field.currentEditor()?.selectAll(nil)
        return true
    }

    /// Depth-limited so a pathological hierarchy can't turn a keystroke into a
    /// long walk. Toolbars and split views nest, but not thirty deep.
    private static func firstSearchField(in view: NSView, depth: Int) -> NSSearchField? {
        if let field = view as? NSSearchField { return field }
        guard depth < 30 else { return nil }
        for sub in view.subviews {
            if let hit = firstSearchField(in: sub, depth: depth + 1) { return hit }
        }
        return nil
    }
}
#endif
