import Foundation

// MARK: - Ordering

/// The pure `order` helpers behind add, remove and move; they read no model state.
extension WordCardModel {
    /// Sets `order` to the position in `items` where it differs. Returns whether anything changed.
    func renumber(_ items: [Sense]) -> Bool {
        var changed = false
        for (position, sense) in items.enumerated() where sense.order != position {
            sense.order = position
            changed = true
        }
        return changed
    }

    func renumber(_ items: [Example]) -> Bool {
        var changed = false
        for (position, example) in items.enumerated() where example.order != position {
            example.order = position
            changed = true
        }
        return changed
    }

    /// `items` with the elements at `source` moved so the first of them lands where `destination`
    /// pointed before the move: SwiftUI's `onMove` contract. Offsets outside `items` are dropped and
    /// `destination` is clamped, so a stale index from the view can never trap.
    static func moved<Element>(
        _ items: [Element],
        fromOffsets source: IndexSet,
        toOffset destination: Int
    ) -> [Element] {
        let offsets = source.filter(items.indices.contains)
        let target = min(max(destination, 0), items.count)
        let moving = offsets.map { items[$0] }
        var remaining = items
        for offset in offsets.reversed() {
            remaining.remove(at: offset)
        }
        let insertAt = target - offsets.filter { $0 < target }.count
        remaining.insert(contentsOf: moving, at: insertAt)
        return remaining
    }
}
