import Foundation
import Testing
@testable import TrailMate

@MainActor
struct RecordingsLibraryTests {
    @Test func persistReloadAndDeleteStayInsideInjectedRoot() throws {
        let runtime = try IsolatedTestRuntime()
        defer { runtime.cleanup() }
        let library = RecordingsLibrary(baseURL: runtime.runtimePaths.recordingsDirectory)
        let draft = makeDraft(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            startedAt: Date(timeIntervalSince1970: 1_750_000_000),
            coordinates: [(25.0330, 121.5654), (25.0335, 121.5650)]
        )

        let persisted = try library.persist(draft)
        let fileURL = try #require(persisted)
        #expect(fileURL.path.hasPrefix(runtime.runtimePaths.recordingsDirectory.path + "/"))
        #expect(FileManager.default.fileExists(atPath: fileURL.path))
        #expect(library.recordings.count == 1)
        #expect(library.recordings[0].points == draft.points)

        let reloaded = RecordingsLibrary(baseURL: runtime.runtimePaths.recordingsDirectory)
        reloaded.loadIndex()
        let session = try #require(reloaded.recordings.first)
        #expect(session.startedAt == draft.startedAt)
        #expect(session.points == draft.points)
        #expect(session.fileURL == fileURL)

        reloaded.delete(session)
        #expect(reloaded.recordings.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))

        let afterDelete = RecordingsLibrary(baseURL: runtime.runtimePaths.recordingsDirectory)
        afterDelete.loadIndex()
        #expect(afterDelete.recordings.isEmpty)
    }

    @Test func emptyDraftCreatesNoGPXOrIndexEntry() throws {
        let runtime = try IsolatedTestRuntime()
        defer { runtime.cleanup() }
        let library = RecordingsLibrary(baseURL: runtime.runtimePaths.recordingsDirectory)
        let draft = RecordingCapture.Draft(
            id: UUID(),
            startedAt: Date(timeIntervalSince1970: 1_750_000_000),
            points: []
        )

        #expect(try library.persist(draft) == nil)
        #expect(library.recordings.isEmpty)
        #expect(gpxFiles(under: runtime.runtimePaths.recordingsDirectory).isEmpty)
    }

    private func makeDraft(
        id: UUID,
        startedAt: Date,
        coordinates: [(Double, Double)]
    ) -> RecordingCapture.Draft {
        RecordingCapture.Draft(
            id: id,
            startedAt: startedAt,
            points: coordinates.enumerated().map { index, coordinate in
                RecordingCapture.Point(
                    timestamp: startedAt.addingTimeInterval(TimeInterval(index)),
                    latitude: coordinate.0,
                    longitude: coordinate.1
                )
            }
        )
    }

    private func gpxFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "gpx" }
    }
}
