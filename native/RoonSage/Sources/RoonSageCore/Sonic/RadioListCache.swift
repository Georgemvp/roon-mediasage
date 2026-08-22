import Foundation

/// The *list* of stations for a category, memoized per rotation bucket.
///
/// **Why this exists.** `dailyRadios(category:)` groups the whole analyzed
/// library by artist, scores every candidate and sorts — and it ran on every
/// appearance of the Radio's screen, because the "already loaded" flag lived in
/// SwiftUI `@State` and dies with the view. Flick to DJ-modi and back and the
/// entire computation happened again.
///
/// It never needed to. The result is a pure function of (category, library,
/// feedback, rotation bucket), and `rotationStamp()` only changes on a new
/// day-part. So: cache on that stamp, and invalidate wherever `SonicLibraryCache`
/// is invalidated — the two have exactly the same inputs.
///
/// Deliberately NOT an actor. It is only ever touched from `RoonClient`, which is
/// `@MainActor`; an actor here would add a suspension point to a lookup whose
/// entire point is to be instant.
@MainActor
final class RadioListCache {
    private struct Key: Hashable {
        let category: String
        let stamp: String
    }

    private var entries: [Key: [RoonClient.SonicRadio]] = [:]

    /// Cached stations for this (category, stamp), or nil on a miss.
    func value(category: String, stamp: String) -> [RoonClient.SonicRadio]? {
        entries[Key(category: category, stamp: stamp)]
    }

    /// Store a freshly built list, dropping entries from older buckets so the
    /// dictionary can't grow across days.
    func store(_ radios: [RoonClient.SonicRadio], category: String, stamp: String) {
        entries = entries.filter { $0.key.stamp == stamp }
        entries[Key(category: category, stamp: stamp)] = radios
    }

    /// Drop everything — the library, the features or the feedback changed, so
    /// every list could be different now.
    func invalidate() {
        entries.removeAll()
    }

    /// How many lists are held (diagnostics + tests).
    var count: Int { entries.count }
}
