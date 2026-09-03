import CoreLocation
import Foundation

// App-wide persisted recording index. Live capture deliberately does not live
// here; each SimulationActor owns a RecordingCapture instead.
@Observable
@MainActor
final class RecordingsLibrary {
    struct Session: Identifiable, Hashable {
        let id: UUID
        let startedAt: Date
        let endedAt: Date?
        let points: [RecordingCapture.Point]
        let fileURL: URL?

        var duration: TimeInterval {
            let last = points.last?.timestamp ?? endedAt ?? startedAt
            return last.timeIntervalSince(startedAt)
        }

        var distanceMeters: Double {
            guard points.count >= 2 else { return 0 }
            var total = 0.0
            for index in 1..<points.count {
                let previous = CLLocation(
                    latitude: points[index - 1].latitude,
                    longitude: points[index - 1].longitude
                )
                let current = CLLocation(
                    latitude: points[index].latitude,
                    longitude: points[index].longitude
                )
                total += previous.distance(from: current)
            }
            return total
        }
    }

    private(set) var recordings: [Session] = []
    let baseURL: URL

    nonisolated static var baseURL: URL {
        AppRuntimePaths.live.recordingsDirectory
    }

    init(baseURL: URL = AppProcessConfiguration.current.runtimePaths.recordingsDirectory) {
        self.baseURL = baseURL.standardizedFileURL
    }

    @discardableResult
    func persist(_ draft: RecordingCapture.Draft) throws -> URL? {
        guard !draft.points.isEmpty else { return nil }

        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HHmmss"

        let dayURL = baseURL.appendingPathComponent(day.string(from: draft.startedAt))
        try FileManager.default.createDirectory(at: dayURL, withIntermediateDirectories: true)

        let filename = "\(time.string(from: draft.startedAt))-\(draft.id.uuidString.prefix(8)).gpx"
        let url = dayURL.appendingPathComponent(filename)
        let gpx = GPXService.generate(timestamped: draft.points)
        try gpx.write(to: url, atomically: true, encoding: .utf8)
        loadIndex()
        return url
    }

    func delete(_ session: Session) {
        if let url = session.fileURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordings.removeAll { $0.id == session.id }
    }

    func loadIndex() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)

        guard let days = try? fileManager.contentsOfDirectory(
            at: baseURL,
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else {
            recordings = []
            return
        }

        var sessions: [Session] = []
        for day in days {
            let isDirectory = (try? day.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDirectory else { continue }
            guard let files = try? fileManager.contentsOfDirectory(
                at: day,
                includingPropertiesForKeys: nil
            ) else { continue }
            for file in files where file.pathExtension.lowercased() == "gpx" {
                if let session = Self.load(from: file) {
                    sessions.append(session)
                }
            }
        }
        recordings = sessions.sorted { $0.startedAt > $1.startedAt }
    }

    private static func load(from url: URL) -> Session? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let parsed = GPXService.parseTimestamped(data: data)
        guard !parsed.isEmpty else { return nil }
        let points = parsed.map {
            RecordingCapture.Point(timestamp: $0.0, latitude: $0.1.latitude, longitude: $0.1.longitude)
        }
        return Session(
            id: UUID(),
            startedAt: points[0].timestamp,
            endedAt: points[points.count - 1].timestamp,
            points: points,
            fileURL: url
        )
    }
}
