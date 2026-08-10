import Foundation

/// Pure queue arithmetic for the on-device player.
///
/// `LocalPlaybackController` owns an `AVPlayer` and an audio session, so its
/// mutations aren't unit-testable; the index bookkeeping that makes them correct
/// is. Every operation here is a pure function over the play order plus the
/// index of the track currently playing, and returns where that track ended up —
/// the engine only has to reload when `currentRemoved` says the playing item is
/// gone.
///
/// Roon's own queue is read + play-from-here only (its extension API exposes no
/// reorder or remove), so these verbs exist for the local engine alone.
public enum LocalQueue {
    /// The play order after a mutation, plus where the playing track moved to.
    /// `currentRemoved` is true when the track that was playing is no longer in
    /// the queue — the caller must load `index` (or stop, when `items` is empty).
    public struct Update<Element> {
        public let items: [Element]
        public let index: Int
        public let currentRemoved: Bool

        public init(items: [Element], index: Int, currentRemoved: Bool) {
            self.items = items
            self.index = index
            self.currentRemoved = currentRemoved
        }
    }

    /// Which queue position plays after `index` finishes on its own, given the
    /// repeat mode — nil when the session should end there.
    ///
    /// This is what makes gapless possible: the engine enqueues this track into
    /// `AVQueuePlayer` *while the current one is still playing*, so the handover
    /// needs no work at the boundary. `loop_one` returns the same index on
    /// purpose — repeating one track is then gapless too, instead of a reload.
    public static func followerIndex(after index: Int, count: Int, loopMode: String) -> Int? {
        guard count > 0, index >= 0, index < count else { return nil }
        if loopMode == "loop_one" { return index }
        if index + 1 < count { return index + 1 }
        return loopMode == "loop" ? 0 : nil
    }

    /// Insert `newItems` either straight after the playing track ("speel hierna")
    /// or at the end ("achteraan toevoegen"). The playing track keeps its
    /// position in both cases, so the engine never reloads.
    ///
    /// An empty queue can't have a "next", so the new items simply become the
    /// queue — that lets a caller treat enqueue-into-nothing as "start playing".
    public static func insert<Element>(
        _ newItems: [Element], into items: [Element], playingAt index: Int, next: Bool
    ) -> [Element] {
        guard !newItems.isEmpty else { return items }
        guard !items.isEmpty else { return newItems }
        guard next else { return items + newItems }
        var out = items
        out.insert(contentsOf: newItems, at: min(max(0, index + 1), items.count))
        return out
    }

    /// Remove the tracks at `offsets`.
    ///
    /// When the playing track survives it keeps playing and `index` follows it.
    /// When it's removed, `index` lands on the next surviving track (the natural
    /// "the queue moved up under you" behaviour) — or the last one when the tail
    /// was removed — and `currentRemoved` tells the engine to load it.
    public static func remove<Element>(
        atOffsets offsets: IndexSet, from items: [Element], playingAt index: Int
    ) -> Update<Element> {
        let kept = items.indices.filter { !offsets.contains($0) }
        let newItems = kept.map { items[$0] }
        guard !newItems.isEmpty else {
            return Update(items: [], index: 0, currentRemoved: true)
        }
        if let pos = kept.firstIndex(of: index) {
            return Update(items: newItems, index: pos, currentRemoved: false)
        }
        // The playing track went with the removal. Prefer the first survivor that
        // came after it; if there is none, the queue's new tail.
        let next = kept.firstIndex(where: { $0 > index }) ?? (kept.count - 1)
        return Update(items: newItems, index: next, currentRemoved: true)
    }

    /// Reorder the queue, following SwiftUI's `onMove` contract: `destination` is
    /// an offset into the ORIGINAL order, naming the element to insert before.
    /// Verified against `Array.move(fromOffsets:toOffset:)` — see
    /// `LocalQueueTests.testMoveMatchesSwiftUISemantics`, which pins the six
    /// cases the formula below was derived from.
    ///
    /// Never reloads: reordering around the playing track doesn't interrupt it,
    /// so `currentRemoved` is always false.
    public static func move<Element>(
        fromOffsets offsets: IndexSet, toOffset destination: Int,
        in items: [Element], playingAt index: Int
    ) -> Update<Element> {
        let moving = offsets.sorted().filter { items.indices.contains($0) }
        guard !moving.isEmpty, destination >= 0, destination <= items.count else {
            return Update(items: items, index: index, currentRemoved: false)
        }
        // Work on original positions so the playing track can be found again by
        // identity rather than by guessing how far the move shifted it.
        let movingSet = Set(moving)
        var order = items.indices.filter { !movingSet.contains($0) }
        let insertAt = destination - moving.filter { $0 < destination }.count
        order.insert(contentsOf: moving, at: min(max(0, insertAt), order.count))
        return Update(items: order.map { items[$0] },
                      index: order.firstIndex(of: index) ?? index,
                      currentRemoved: false)
    }
}
