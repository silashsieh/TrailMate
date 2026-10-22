import Foundation

// Ordering helpers for the saved-items library (epic 029). Pure transforms over
// arrays of Identifiable items so the reorder/sort logic is unit-testable
// without UserDefaults, disk, or a live List.
enum LibraryOrder {
    // Apply a drop expressed in stable identities rather than offsets captured
    // from a transient filtered view. All moved and destination IDs must belong
    // to the group, so a drop onto another section remains a no-op.
    nonisolated static func moveWithinGroup<T: Identifiable>(
        _ items: [T],
        groupIDs: Set<T.ID>,
        movingIDs: [T.ID],
        before destinationID: T.ID?
    ) -> [T] {
        let slots = items.indices.filter { groupIDs.contains(items[$0].id) }
        let group = slots.map { items[$0] }
        let movingIDSet = Set(movingIDs)

        guard !movingIDSet.isEmpty,
              movingIDSet.isSubset(of: groupIDs),
              destinationID.map({ groupIDs.contains($0) }) ?? true else {
            return items
        }

        let moving = group.filter { movingIDSet.contains($0.id) }
        var reordered = group.filter { !movingIDSet.contains($0.id) }

        if let destinationID {
            // Dropping immediately before the moving item itself is a no-op.
            guard !movingIDSet.contains(destinationID),
                  let destination = reordered.firstIndex(where: { $0.id == destinationID }) else {
                return items
            }
            reordered.insert(contentsOf: moving, at: destination)
        } else {
            reordered.append(contentsOf: moving)
        }

        var result = items
        for (slot, element) in zip(slots, reordered) {
            result[slot] = element
        }
        return result
    }

    // Reorder the subset of `items` whose ids are in `groupIDs` — a single
    // folder's rows — using SwiftUI `List.onMove` offset semantics, then write
    // the new relative order back into exactly the slots that subset occupied in
    // the global array. Every item outside the group keeps its absolute
    // position, so reordering one folder never disturbs another.
    nonisolated static func moveWithinGroup<T: Identifiable>(
        _ items: [T],
        groupIDs: Set<T.ID>,
        fromOffsets source: IndexSet,
        toOffset destination: Int
    ) -> [T] {
        let slots = items.indices.filter { groupIDs.contains(items[$0].id) }
        guard !slots.isEmpty else { return items }
        let group = applyOffsetMove(slots.map { items[$0] }, fromOffsets: source, toOffset: destination)
        var result = items
        for (slot, element) in zip(slots, group) {
            result[slot] = element
        }
        return result
    }

    // SwiftUI `List.onMove` semantics without importing SwiftUI: pull the
    // elements at `source` out, then re-insert them so they land just before
    // what was originally at `destination` (`destination == count` appends).
    nonisolated static func applyOffsetMove<E>(
        _ array: [E],
        fromOffsets source: IndexSet,
        toOffset destination: Int
    ) -> [E] {
        let moving = source.sorted().map { array[$0] }
        var result = array
        for index in source.sorted(by: >) {
            result.remove(at: index)
        }
        let insertAt = destination - source.filter { $0 < destination }.count
        result.insert(contentsOf: moving, at: insertAt)
        return result
    }

    // Sort items by a persisted id order. Items present in `order` come first,
    // in that order; items absent from it (e.g. just-saved routes the order
    // sidecar hasn't caught up with) sort by `fallback` and lead the list — so a
    // brand-new save lands at the top, matching the prior newest-first default.
    nonisolated static func ordered<T: Identifiable>(
        _ items: [T],
        byIDOrder order: [T.ID],
        fallback: (T, T) -> Bool
    ) -> [T] {
        var rank: [T.ID: Int] = [:]
        for (index, id) in order.enumerated() where rank[id] == nil {
            rank[id] = index
        }
        let known = items.filter { rank[$0.id] != nil }
            .sorted { rank[$0.id]! < rank[$1.id]! }
        let unknown = items.filter { rank[$0.id] == nil }
            .sorted(by: fallback)
        return unknown + known
    }
}
