import CoreLocation
import Foundation

@Observable
@MainActor
final class RecorderService {
    struct Point: Codable, Hashable {
        let timestamp: Date
        let latitude: Double
        let longitude: Double

        var coordinate: CLLocationCoordinate2D {
            CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
    }

    struct Session: Identifiable, Hashable {
        let id: UUID
        let startedAt: Date
        let endedAt: Date?
        let points: [Point]
        let fileURL: URL?

        var duration: TimeInterval {
            let last = points.last?.timestamp ?? endedAt ?? startedAt
            return last.timeIntervalSince(startedAt)
        }

        var distanceMeters: Double {
            guard points.count >= 2 else { return 0 }
            var total = 0.0
            for i in 1..<points.count {
                let a = CLLocation(latitude: points[i - 1].latitude, longitude: points[i - 1].longitude)
                let b = CLLocation(latitude: points[i].latitude, longitude: points[i].longitude)
                total += a.distance(from: b)
            }
            return total
        }
    }

    var isRecording = false
    var currentPointCount = 0
    private(set) var recordings: [Session] = []

    private var startedAt: Date?
    private var bufferedPoints: [Point] = []
    private var currentID = UUID()

    nonisolated static var baseURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("TrailMate").appendingPathComponent("recordings")
    }

    func start() {
        guard !isRecording else { return }
        startedAt = Date()
        currentID = UUID()
        bufferedPoints = []
        currentPointCount = 0
        isRecording = true
    }

    func append(_ coord: CLLocationCoordinate2D) {
        guard isRecording else { return }
        bufferedPoints.append(Point(timestamp: Date(), latitude: coord.latitude, longitude: coord.longitude))
        currentPointCount = bufferedPoints.count
    }

    @discardableResult
    func stop() throws -> URL? {
        guard isRecording else { return nil }
        isRecording = false
        let started = startedAt ?? Date()
        let id = currentID
        let points = bufferedPoints
        startedAt = nil
        bufferedPoints = []
        currentPointCount = 0

        guard !points.isEmpty else { return nil }

        let url = try persist(id: id, startedAt: started, points: points)
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
        let fm = FileManager.default
        let base = Self.baseURL
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)

        guard let days = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.isDirectoryKey]) else {
            recordings = []
            return
        }

        var sessions: [Session] = []
        for day in days {
            let isDir = (try? day.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard isDir else { continue }
            guard let files = try? fm.contentsOfDirectory(at: day, includingPropertiesForKeys: nil) else { continue }
            for file in files where file.pathExtension.lowercased() == "gpx" {
                if let session = Self.load(from: file) {
                    sessions.append(session)
                }
            }
        }
        recordings = sessions.sorted(by: { $0.startedAt > $1.startedAt })
    }

    private func persist(id: UUID, startedAt: Date, points: [Point]) throws -> URL {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter()
        time.locale = Locale(identifier: "en_US_POSIX")
        time.dateFormat = "HHmmss"

        let fm = FileManager.default
        let dayURL = Self.baseURL.appendingPathComponent(day.string(from: startedAt))
        try fm.createDirectory(at: dayURL, withIntermediateDirectories: true)

        let filename = "\(time.string(from: startedAt))-\(id.uuidString.prefix(8)).gpx"
        let url = dayURL.appendingPathComponent(filename)
        let gpx = GPXService.generate(timestamped: points)
        try gpx.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private static func load(from url: URL) -> Session? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let parsed = GPXService.parseTimestamped(data: data)
        guard !parsed.isEmpty else { return nil }
        let points = parsed.map { Point(timestamp: $0.0, latitude: $0.1.latitude, longitude: $0.1.longitude) }
        let firstStamp = points.first!.timestamp
        let lastStamp = points.last!.timestamp
        return Session(
            id: UUID(),
            startedAt: firstStamp,
            endedAt: lastStamp,
            points: points,
            fileURL: url
        )
    }
}
