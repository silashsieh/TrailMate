import CoreLocation
import Foundation
import MapKit
import Testing
@testable import TrailMate

// Pure logic behind the saved-items library UX (epic 029): the reorder/grouping
// transforms that back drag-to-reorder + folders, and the map-framing math
// behind auto-pan-on-select. Disk/UserDefaults persistence isn't exercised here
// — the app-hosted test process shares the real Application Support dir (see
// testing.md), so these cover the order/region *logic* the persistence wraps.

private struct Item: Identifiable, Equatable {
    let id: Int
    var group: String?
}

struct LibraryOrderTests {
    // MARK: applyOffsetMove — SwiftUI List.onMove offset semantics

    @Test func moveDownReinsertsBeforeDestination() {
        // Drag index 0 to the end (destination == count appends).
        let result = LibraryOrder.applyOffsetMove([1, 2, 3, 4], fromOffsets: IndexSet(integer: 0), toOffset: 4)
        #expect(result == [2, 3, 4, 1])
    }

    @Test func moveUpInsertsBeforeDestination() {
        // Drag index 2 to offset 0 → lands first.
        let result = LibraryOrder.applyOffsetMove([1, 2, 3, 4], fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(result == [3, 1, 2, 4])
    }

    @Test func moveContiguousBlockKeepsInternalOrder() {
        let result = LibraryOrder.applyOffsetMove([1, 2, 3, 4, 5], fromOffsets: IndexSet([0, 1]), toOffset: 5)
        #expect(result == [3, 4, 5, 1, 2])
    }

    // MARK: moveWithinGroup — reorder one folder, leave the others fixed

    @Test func reorderWithinGroupLeavesOtherGroupsInPlace() {
        // Global order interleaves two folders; reordering "A" must not disturb
        // the absolute positions the "B" items occupy.
        let items = [
            Item(id: 1, group: "A"),
            Item(id: 2, group: "B"),
            Item(id: 3, group: "A"),
            Item(id: 4, group: "B"),
            Item(id: 5, group: "A"),
        ]
        let groupA = Set(items.filter { $0.group == "A" }.map(\.id))  // {1,3,5}
        // Within A's rows [1,3,5], move the first (1) to the end → [3,5,1].
        let result = LibraryOrder.moveWithinGroup(items, groupIDs: groupA, fromOffsets: IndexSet(integer: 0), toOffset: 3)

        // A's slots (global indices 0,2,4) now hold 3,5,1; B's slots (1,3) untouched.
        #expect(result.map(\.id) == [3, 2, 5, 4, 1])
    }

    @Test func reorderUngroupedGroupAddressedByNil() {
        let items = [
            Item(id: 1, group: nil),
            Item(id: 2, group: "A"),
            Item(id: 3, group: nil),
        ]
        let ungrouped = Set(items.filter { $0.group == nil }.map(\.id))  // {1,3}
        let result = LibraryOrder.moveWithinGroup(items, groupIDs: ungrouped, fromOffsets: IndexSet(integer: 1), toOffset: 0)
        #expect(result.map(\.id) == [3, 2, 1])
    }

    @Test func moveWithEmptyGroupIsNoOp() {
        let items = [Item(id: 1, group: "A")]
        let result = LibraryOrder.moveWithinGroup(items, groupIDs: Set<Int>(), fromOffsets: IndexSet(integer: 0), toOffset: 1)
        #expect(result == items)
    }

    // MARK: ordered — persisted id order, with unknowns leading by fallback

    @Test func knownItemsFollowPersistedOrder() {
        let items = [Item(id: 1, group: nil), Item(id: 2, group: nil), Item(id: 3, group: nil)]
        let result = LibraryOrder.ordered(items, byIDOrder: [3, 1, 2], fallback: { $0.id < $1.id })
        #expect(result.map(\.id) == [3, 1, 2])
    }

    @Test func unknownItemsLeadSortedByFallback() {
        // 1 and 3 are persisted; 5 and 4 are new (absent from the order) and lead,
        // sorted by the fallback (here: descending id).
        let items = [Item(id: 1, group: nil), Item(id: 3, group: nil), Item(id: 4, group: nil), Item(id: 5, group: nil)]
        let result = LibraryOrder.ordered(items, byIDOrder: [3, 1], fallback: { $0.id > $1.id })
        #expect(result.map(\.id) == [5, 4, 3, 1])
    }

    @Test func duplicateIDsInOrderDoNotCrash() {
        let items = [Item(id: 1, group: nil), Item(id: 2, group: nil)]
        let result = LibraryOrder.ordered(items, byIDOrder: [2, 2, 1], fallback: { $0.id < $1.id })
        #expect(result.map(\.id) == [2, 1])
    }
}

struct MapRegionMathTests {
    private func approx(_ a: Double, _ b: Double, tol: Double = 1e-6) -> Bool {
        abs(a - b) <= tol
    }

    @Test func boundingRegionCentersAndPadsTwoPoints() throws {
        let coords = [
            CLLocationCoordinate2D(latitude: 25.00, longitude: 121.50),
            CLLocationCoordinate2D(latitude: 25.10, longitude: 121.70),
        ]
        let region = try #require(MapRegionMath.boundingRegion(coords, paddingFactor: 1.3))
        #expect(approx(region.center.latitude, 25.05))
        #expect(approx(region.center.longitude, 121.60))
        // (max-min) * paddingFactor, both well above the meters floor.
        #expect(approx(region.span.latitudeDelta, 0.10 * 1.3))
        #expect(approx(region.span.longitudeDelta, 0.20 * 1.3))
    }

    @Test func boundingRegionFloorsADegeneratePoint() throws {
        let p = CLLocationCoordinate2D(latitude: 25.0, longitude: 121.0)
        let region = try #require(MapRegionMath.boundingRegion([p], minimumEdgeMeters: 400))
        #expect(approx(region.center.latitude, 25.0))
        #expect(approx(region.center.longitude, 121.0))
        // A zero-extent box floors to the meters-based minimum, never collapses.
        #expect(region.span.latitudeDelta > 0.003)
        #expect(region.span.longitudeDelta > 0.003)
        // Longitude degrees are wider than latitude degrees away from the equator.
        #expect(region.span.longitudeDelta > region.span.latitudeDelta)
    }

    @Test func boundingRegionEmptyIsNil() {
        #expect(MapRegionMath.boundingRegion([]) == nil)
    }

    @Test func regionAroundPointCentersWithPositiveSpan() {
        let p = CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654)
        let region = MapRegionMath.region(around: p, edgeMeters: 1_200)
        #expect(approx(region.center.latitude, p.latitude, tol: 1e-9))
        #expect(approx(region.center.longitude, p.longitude, tol: 1e-9))
        // ~1200 m ≈ 0.0108° latitude; allow a band for MapKit's own conversion.
        #expect(region.span.latitudeDelta > 0.008)
        #expect(region.span.latitudeDelta < 0.013)
    }
}
