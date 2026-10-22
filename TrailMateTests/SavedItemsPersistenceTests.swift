import Foundation
import Testing
@testable import TrailMate

@MainActor
struct SavedWaypointsStoreTests {
    @Test func lifecycleAndGroupOrderSurviveRelaunch() throws {
        let runtime = try IsolatedTestRuntime()
        defer { runtime.cleanup() }

        let first = SavedWaypoint(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "First",
            latitude: 25.033,
            longitude: 121.5654,
            category: nil
        )
        let second = SavedWaypoint(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            name: "Second",
            latitude: 25.0478,
            longitude: 121.517,
            category: nil
        )
        let third = SavedWaypoint(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!,
            name: "Third",
            latitude: 25.0375,
            longitude: 121.5637,
            category: "Trips"
        )
        let fourth = SavedWaypoint(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000004")!,
            name: "Fourth",
            latitude: 25.034,
            longitude: 121.5645,
            category: "Trips"
        )

        let store = SavedWaypointsStore(defaults: runtime.defaults)
        try store.load()
        try store.save(first)
        try store.save(second)
        try store.save(third)
        try store.save(fourth)

        try store.move(inCategory: nil, movingIDs: [first.id], before: nil)
        try store.move(inCategory: "Trips", movingIDs: [fourth.id], before: third.id)
        try store.rename(second, to: "Renamed")
        try store.setCategory("Trips", for: first)
        try store.setCategory(nil, for: first)
        try store.delete(fourth)

        let relaunchedDefaults = try #require(UserDefaults(suiteName: runtime.defaultsSuiteName))
        let relaunched = SavedWaypointsStore(defaults: relaunchedDefaults)
        try relaunched.load()

        #expect(relaunched.waypoints.map(\.id) == [second.id, first.id, third.id])
        #expect(relaunched.waypoints.first?.name == "Renamed")
        #expect(relaunched.waypoints.first(where: { $0.id == first.id })?.category == nil)
        #expect(relaunched.waypoints.first(where: { $0.id == third.id })?.category == "Trips")
    }

    @Test func legacyWaypointWithoutCategoryStillLoads() throws {
        let runtime = try IsolatedTestRuntime()
        defer { runtime.cleanup() }
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000010")!
        let legacy: [[String: Any]] = [[
            "id": id.uuidString,
            "name": "Legacy",
            "latitude": 25.033,
            "longitude": 121.5654,
        ]]
        runtime.defaults.set(try JSONSerialization.data(withJSONObject: legacy), forKey: "savedWaypoints")

        let store = SavedWaypointsStore(defaults: runtime.defaults)
        try store.load()

        #expect(store.waypoints.count == 1)
        #expect(store.waypoints.first?.id == id)
        #expect(store.waypoints.first?.category == nil)
    }
}

@MainActor
struct SavedRoutesStoreTests {
    @Test func lifecycleAndGroupOrderSurviveRelaunch() throws {
        let runtime = try IsolatedTestRuntime()
        defer { runtime.cleanup() }

        let first = makeRoute(idSuffix: 1, name: "First", timestamp: 1, category: nil)
        let second = makeRoute(idSuffix: 2, name: "Second", timestamp: 2, category: nil)
        let third = makeRoute(idSuffix: 3, name: "Third", timestamp: 3, category: "Trips")
        let fourth = makeRoute(idSuffix: 4, name: "Fourth", timestamp: 4, category: "Trips")

        let store = SavedRoutesStore(baseURL: runtime.runtimePaths.savedRoutesDirectory)
        try store.save(first)
        try store.save(second)
        try store.save(third)
        try store.save(fourth)

        store.move(inCategory: nil, movingIDs: [second.id], before: nil)
        store.move(inCategory: "Trips", movingIDs: [third.id], before: fourth.id)

        var renamed = first
        renamed.name = "Renamed"
        try store.save(renamed)
        store.setCategory("Trips", for: second)
        store.setCategory(nil, for: second)
        store.delete(fourth)

        let relaunched = SavedRoutesStore(baseURL: runtime.runtimePaths.savedRoutesDirectory)
        relaunched.load()

        #expect(relaunched.routes.map(\.id) == [third.id, first.id, second.id])
        #expect(relaunched.routes.first(where: { $0.id == first.id })?.name == "Renamed")
        #expect(relaunched.routes.first(where: { $0.id == second.id })?.category == nil)
        #expect(relaunched.routes.first(where: { $0.id == third.id })?.category == "Trips")
        #expect(FileManager.default.fileExists(atPath: runtime.runtimePaths.savedRoutesDirectory
            .appendingPathComponent("order.json").path))
        #expect(!FileManager.default.fileExists(atPath: runtime.runtimePaths.savedRoutesDirectory
            .appendingPathComponent("\(fourth.id.uuidString).json").path))
    }

    @Test func legacyRouteWithoutOptionalFieldsStillLoads() throws {
        let runtime = try IsolatedTestRuntime()
        defer { runtime.cleanup() }
        let directory = runtime.runtimePaths.savedRoutesDirectory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000020")!
        let legacy: [String: Any] = [
            "id": id.uuidString,
            "name": "Legacy",
            "createdAt": 123.0,
            "transportModeRaw": "walk",
            "coordinates": [
                ["lat": 25.033, "lon": 121.5654],
                ["lat": 25.034, "lon": 121.5664],
            ],
            "source": "imported",
        ]
        let data = try JSONSerialization.data(withJSONObject: legacy)
        try data.write(to: directory.appendingPathComponent("\(id.uuidString).json"), options: .atomic)

        let store = SavedRoutesStore(baseURL: directory)
        store.load()

        let route = try #require(store.routes.first)
        #expect(route.id == id)
        #expect(route.customSpeedKmh == nil)
        #expect(route.sourceDetail == nil)
        #expect(route.fromWaypoint == nil)
        #expect(route.toWaypoint == nil)
        #expect(route.stopWaypoints == nil)
        #expect(route.category == nil)
    }

    private func makeRoute(
        idSuffix: Int,
        name: String,
        timestamp: TimeInterval,
        category: String?
    ) -> SavedRoute {
        SavedRoute(
            id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", idSuffix))!,
            name: name,
            createdAt: Date(timeIntervalSinceReferenceDate: timestamp),
            transportModeRaw: TransportMode.walk.rawValue,
            customSpeedKmh: nil,
            coordinates: [
                .init(lat: 25.033, lon: 121.5654),
                .init(lat: 25.034, lon: 121.5664),
            ],
            source: "calculated",
            sourceDetail: nil,
            fromWaypoint: nil,
            toWaypoint: nil,
            stopWaypoints: nil,
            category: category
        )
    }
}

struct SavedItemStableMoveTests {
    private struct Item: Identifiable, Equatable {
        let id: Int
        let group: String?
    }

    @Test func stableIDsMoveWithinInterleavedGroup() {
        let items = [
            Item(id: 1, group: "A"),
            Item(id: 2, group: "B"),
            Item(id: 3, group: "A"),
            Item(id: 4, group: "B"),
            Item(id: 5, group: "A"),
        ]

        let moved = LibraryOrder.moveWithinGroup(
            items,
            groupIDs: Set([1, 3, 5]),
            movingIDs: [1],
            before: nil
        )

        #expect(moved.map(\.id) == [3, 2, 5, 4, 1])
    }

    @Test func stableIDsRejectCrossGroupDrop() {
        let items = [Item(id: 1, group: "A"), Item(id: 2, group: "B")]

        let moved = LibraryOrder.moveWithinGroup(
            items,
            groupIDs: Set([2]),
            movingIDs: [1],
            before: 2
        )

        #expect(moved == items)
    }

    @Test func dragPayloadKeepsLibraryTypesDistinct() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000030")!

        #expect(SavedItemDragPayload.waypointID(from: SavedItemDragPayload.waypoint(id)) == id)
        #expect(SavedItemDragPayload.routeID(from: SavedItemDragPayload.route(id)) == id)
        #expect(SavedItemDragPayload.routeID(from: SavedItemDragPayload.waypoint(id)) == nil)
        #expect(SavedItemDragPayload.waypointID(from: SavedItemDragPayload.route(id)) == nil)
    }
}
