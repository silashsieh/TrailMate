import Darwin
import Foundation
import Testing
@testable import TrailMate

// AI command socket lifecycle and framing (epic 019, coverage owed by 033).
// Every server here listens on a socket under a private /tmp root and hands
// commands to a recording fake, so nothing touches the user's Application
// Support, defaults, sessions, or the production ai.sock.
@MainActor
struct CommandServerSocketTests {
    private struct Harness {
        let runtime: IsolatedTestRuntime
        let dispatcher: FakeCommandDispatcher
        let socketURL: URL
        let server: CommandServer

        var socketPath: String { socketURL.path }
        var socketDirectory: URL { socketURL.deletingLastPathComponent() }

        func connect() throws -> CommandSocketClient {
            try CommandSocketClient(path: socketPath)
        }

        // A client that has consumed the greeting, ready for commands.
        func greetedClient() async throws -> CommandSocketClient {
            let client = try connect()
            let greeting = try await client.readLine()
            #expect(greeting == CommandServerSocketTests.expectedGreeting)
            return client
        }
    }

    fileprivate static let expectedGreeting = aiGreetingLine().trimmingCharacters(in: .newlines)

    // The socket lives in a directory that does not exist yet, so start()
    // has to create it and the owner-only mode is observable.
    private func makeHarness(configuration: CommandServer.Configuration = .live) throws -> Harness {
        let runtime = try IsolatedTestRuntime()
        let socketURL = runtime.rootDirectory
            .appendingPathComponent("ai-control", isDirectory: true)
            .appendingPathComponent("ai.sock", isDirectory: false)
        let dispatcher = FakeCommandDispatcher()
        let server = CommandServer(dispatcher: dispatcher, socketURL: socketURL, configuration: configuration)
        return Harness(runtime: runtime, dispatcher: dispatcher, socketURL: socketURL, server: server)
    }

    private func posixPermissions(at path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return try #require(attributes[.posixPermissions] as? Int)
    }

    private func fileType(at path: String) throws -> FileAttributeType? {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        return attributes[.type] as? FileAttributeType
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while ContinuousClock.now < deadline {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }

    private func responseLine(seq: Int) -> String {
        CommandResponse.success(.object(["seq": .int(seq)])).line().trimmingCharacters(in: .newlines)
    }

    // MARK: - Creation, permissions, unlink

    @Test func startCreatesOwnerOnlySocketAndStopUnlinksIt() async throws {
        let h = try makeHarness()
        defer { h.runtime.cleanup() }
        #expect(h.socketPath.hasPrefix("/tmp/TrailMate-Tests-"))
        #expect(h.socketURL != AppRuntimePaths.live.aiSocketURL)
        #expect(!FileManager.default.fileExists(atPath: h.socketDirectory.path))

        h.server.start()

        #expect(try fileType(at: h.socketPath) == .typeSocket)
        #expect(try posixPermissions(at: h.socketPath) == 0o700)
        #expect(try posixPermissions(at: h.socketDirectory.path) == 0o700)
        #expect(await eventually { h.server.acceptLoopCountForTesting == 1 })
        #expect(await eventually { h.dispatcher.logs.contains("AI control: listening at \(h.socketPath)") })

        h.server.stop()

        #expect(!FileManager.default.fileExists(atPath: h.socketPath))
        #expect(await eventually { h.server.acceptLoopCountForTesting == 0 })
        #expect(await eventually { h.dispatcher.logs.contains("AI control: stopped.") })
        #expect(throws: CommandSocketClient.ClientError.connectFailed(errno: ENOENT)) {
            try h.connect()
        }
        #expect(h.dispatcher.commands.isEmpty)
    }

    @Test func startIsIdempotentAndStopWithoutStartIsANoOp() async throws {
        let h = try makeHarness()
        defer { h.runtime.cleanup() }

        h.server.stop()
        #expect(!FileManager.default.fileExists(atPath: h.socketPath))

        h.server.start()
        h.server.start()
        #expect(await eventually { h.dispatcher.logs.contains { $0.hasPrefix("AI control: listening") } })
        #expect(h.server.acceptLoopCountForTesting == 1)
        #expect(h.dispatcher.logs.filter { $0.hasPrefix("AI control: listening") }.count == 1)

        let client = try await h.greetedClient()
        client.close()

        h.server.stop()
        h.server.stop()
        #expect(await eventually { h.server.acceptLoopCountForTesting == 0 })
        // Log lines arrive through a MainActor hop, so wait for the one and
        // only then assert there is no second.
        #expect(await eventually { h.dispatcher.logs.contains("AI control: stopped.") })
        #expect(h.dispatcher.logs.filter { $0 == "AI control: stopped." }.count == 1)
    }

    @Test func staleSocketNodeFromAPriorRunIsReclaimed() async throws {
        let h = try makeHarness()
        defer { h.runtime.cleanup() }
        try FileManager.default.createDirectory(at: h.socketDirectory, withIntermediateDirectories: true)

        // Bind and abandon a listener without unlink(), as a crashed process
        // would: the node stays, nobody accepts.
        let stale = socket(AF_UNIX, SOCK_STREAM, 0)
        #expect(stale >= 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = h.socketPath.utf8CString
        withUnsafeMutablePointer(to: &addr.sun_path) { sunPath in
            sunPath.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dst in
                pathBytes.withUnsafeBufferPointer { src in
                    dst.update(from: src.baseAddress!, count: src.count)
                }
            }
        }
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.bind(stale, sa, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        #expect(bound == 0)
        close(stale)
        #expect(try fileType(at: h.socketPath) == .typeSocket)
        #expect(throws: CommandSocketClient.ClientError.connectFailed(errno: ECONNREFUSED)) {
            try h.connect()
        }

        h.server.start()
        let client = try await h.greetedClient()
        try await client.send("STATUS\n")
        #expect(try await client.readLine() == responseLine(seq: 0))
        client.close()
        h.server.stop()
        #expect(!FileManager.default.fileExists(atPath: h.socketPath))
    }

    @Test func overlongSocketPathFailsCleanlyWithoutListening() async throws {
        let runtime = try IsolatedTestRuntime()
        defer { runtime.cleanup() }
        let longName = String(repeating: "x", count: SocketPath.maxSunPathBytes)
        let socketURL = runtime.rootDirectory.appendingPathComponent("\(longName).sock", isDirectory: false)
        let dispatcher = FakeCommandDispatcher()
        let server = CommandServer(dispatcher: dispatcher, socketURL: socketURL)

        #expect(throws: SocketPath.Error.self) {
            try SocketPath.resolve(socketURL)
        }
        #expect(SocketPath.displayPath(socketURL) == socketURL.path)

        server.start()

        #expect(await eventually { dispatcher.logs.contains { $0.hasPrefix("AI control: socket path error") } })
        #expect(dispatcher.logs.contains { $0.contains("AF_UNIX limit") })
        #expect(!FileManager.default.fileExists(atPath: socketURL.path))
        #expect(server.acceptLoopCountForTesting == 0)
        server.stop()
        #expect(!dispatcher.logs.contains("AI control: stopped."))
    }

    // MARK: - Greeting and framing

    @Test func greetingAdvertisesServiceAndProtocolVersion() async throws {
        let h = try makeHarness()
        defer { h.runtime.cleanup() }
        h.server.start()
        defer { h.server.stop() }

        let client = try h.connect()
        #expect(try await client.readLine() == #"{"data":{"protocol":1,"service":"trailmate"},"ok":true}"#)
        #expect(h.dispatcher.commands.isEmpty)
        client.close()
    }

    @Test func fragmentedLineIsDispatchedOnceWhenComplete() async throws {
        let h = try makeHarness()
        defer { h.runtime.cleanup() }
        h.server.start()
        defer { h.server.stop() }
        let client = try await h.greetedClient()

        try await client.send("STA")
        await #expect(throws: CommandSocketClient.ClientError.timedOut) {
            try await client.readLine(timeout: .milliseconds(100))
        }
        #expect(h.dispatcher.commands.isEmpty)

        try await client.send("TUS\n")
        #expect(try await client.readLine() == responseLine(seq: 0))
        #expect(h.dispatcher.commands == [.status])

        // A fragment boundary inside the second of two lines.
        try await client.send("DEVICES\nTELEPORT DEV-1 25.03")
        #expect(try await client.readLine() == responseLine(seq: 1))
        try await client.send("3 121.5654\n")
        #expect(try await client.readLine() == responseLine(seq: 2))
        #expect(h.dispatcher.commands == [
            .status,
            .devices,
            .teleport(udid: "DEV-1", latitude: 25.033, longitude: 121.5654)
        ])
        client.close()
    }

    @Test func multipleLinesInOneWriteAreDispatchedInOrder() async throws {
        let h = try makeHarness()
        defer { h.runtime.cleanup() }
        h.server.start()
        defer { h.server.stop() }
        let client = try await h.greetedClient()

        try await client.send("DEVICES\nSTATUS\nPLAY DEV-1\nSEEK DEV-1 0.5\n")
        for seq in 0..<4 {
            #expect(try await client.readLine() == responseLine(seq: seq))
        }
        #expect(h.dispatcher.commands == [.devices, .status, .play(udid: "DEV-1"), .seek(udid: "DEV-1", progress: 0.5)])
        client.close()
    }

    @Test func blankCRLFAndInvalidUTF8LinesProduceNoResponse() async throws {
        let h = try makeHarness()
        defer { h.runtime.cleanup() }
        h.server.start()
        defer { h.server.stop() }
        let client = try await h.greetedClient()

        try await client.send("\r\n\n   \n")
        try await client.send(bytes: [0xFF, 0xFE, 0x0A])
        try await client.send("status\r\n")
        #expect(try await client.readLine() == responseLine(seq: 0))
        await #expect(throws: CommandSocketClient.ClientError.timedOut) {
            try await client.readLine(timeout: .milliseconds(100))
        }
        #expect(h.dispatcher.commands == [.status])
        client.close()
    }

    @Test func parseErrorsAreAnsweredWithoutDispatchAndKeepTheConnection() async throws {
        let h = try makeHarness()
        defer { h.runtime.cleanup() }
        h.server.start()
        defer { h.server.stop() }
        let client = try await h.greetedClient()

        try await client.send("BOGUS\nTELEPORT DEV-1\n")
        #expect(try await client.readLine() == #"{"code":"parse_error","error":"unknown command 'BOGUS'","ok":false}"#)
        #expect(try await client.readLine() == #"{"code":"parse_error","error":"'TELEPORT' is missing arguments","ok":false}"#)
        #expect(h.dispatcher.commands.isEmpty)

        try await client.send("STATUS\n")
        #expect(try await client.readLine() == responseLine(seq: 0))
        #expect(h.dispatcher.commands == [.status])
        client.close()
    }

    @Test func oversizedLineIsRejectedAndThatConnectionIsDropped() async throws {
        let h = try makeHarness()
        defer { h.runtime.cleanup() }
        h.server.start()
        defer { h.server.stop() }
        let client = try await h.greetedClient()

        let cap = CommandServer.Configuration.live.maxLineBytes
        #expect(cap == 64 * 1024)
        do {
            try await client.send(bytes: [UInt8](repeating: UInt8(ascii: "A"), count: cap + 4096))
        } catch CommandSocketClient.ClientError.writeFailed(errno: EPIPE) {
            // The server may drop the connection before the tail is written;
            // the rejection line below is the contract.
        }

        #expect(try await client.readLine() == #"{"code":"line_too_long","error":"command exceeds \#(cap) bytes","ok":false}"#)
        #expect(try await client.awaitEOF())
        #expect(h.dispatcher.commands.isEmpty)
        #expect(await eventually { h.server.connectionCountForTesting == 0 })

        // The listener itself is unaffected.
        let next = try await h.greetedClient()
        try await next.send("STATUS\n")
        #expect(try await next.readLine() == responseLine(seq: 0))
        next.close()
    }

    @Test func largeButTerminatedLineUnderTheCapIsAccepted() async throws {
        let h = try makeHarness()
        defer { h.runtime.cleanup() }
        h.server.start()
        defer { h.server.stop() }
        let client = try await h.greetedClient()

        // Padding is whitespace, so the parser still sees a single STATUS verb.
        let padding = String(repeating: " ", count: 60 * 1024)
        try await client.send("STATUS\(padding)\n")
        #expect(try await client.readLine() == responseLine(seq: 0))
        #expect(h.dispatcher.commands == [.status])
        client.close()
    }

    // MARK: - Client close, stop, epochs

    @Test func clientCloseUntracksTheConnectionAndAcceptContinues() async throws {
        let h = try makeHarness()
        defer { h.runtime.cleanup() }
        h.server.start()
        defer { h.server.stop() }

        let first = try await h.greetedClient()
        #expect(await eventually { h.server.connectionCountForTesting == 1 })
        try await first.send("STA")
        first.close()
        #expect(await eventually { h.server.connectionCountForTesting == 0 })
        #expect(h.dispatcher.commands.isEmpty)

        let second = try await h.greetedClient()
        try await second.send("STATUS\n")
        #expect(try await second.readLine() == responseLine(seq: 0))
        #expect(h.dispatcher.commands == [.status])
        second.close()
        #expect(await eventually { h.server.connectionCountForTesting == 0 })
    }

    @Test func stopDisconnectsIdleClientsAndRefusesNewOnes() async throws {
        let h = try makeHarness()
        defer { h.runtime.cleanup() }
        h.server.start()
        let idle = try await h.greetedClient()
        let other = try await h.greetedClient()
        #expect(await eventually { h.server.connectionCountForTesting == 2 })

        h.server.stop()

        #expect(try await idle.awaitEOF())
        #expect(try await other.awaitEOF())
        #expect(await eventually { h.server.connectionCountForTesting == 0 })
        #expect(await eventually { h.server.acceptLoopCountForTesting == 0 })
        #expect(!FileManager.default.fileExists(atPath: h.socketPath))
        #expect(throws: CommandSocketClient.ClientError.connectFailed(errno: ENOENT)) {
            try h.connect()
        }
        #expect(h.dispatcher.commands.isEmpty)
        idle.close()
        other.close()
    }

    @Test func rapidStopStartEpochsLeaveExactlyOneLiveListener() async throws {
        let h = try makeHarness()
        defer { h.runtime.cleanup() }

        for _ in 0..<25 {
            h.server.start()
            h.server.stop()
        }
        #expect(await eventually { h.server.acceptLoopCountForTesting == 0 })
        #expect(!FileManager.default.fileExists(atPath: h.socketPath))
        #expect(!h.dispatcher.logs.contains { $0.contains("accept() failed") })

        // Every epoch serves its own clients and retires them on stop.
        for epoch in 0..<8 {
            h.server.start()
            let client = try await h.greetedClient()
            try await client.send("STATUS\n")
            #expect(try await client.readLine() == responseLine(seq: epoch))
            h.server.stop()
            #expect(try await client.awaitEOF())
            client.close()
        }
        #expect(await eventually { h.server.acceptLoopCountForTesting == 0 })
        #expect(await eventually { h.server.connectionCountForTesting == 0 })
        #expect(h.dispatcher.commands.count == 8)
        #expect(!h.dispatcher.logs.contains { $0.contains("accept() failed") })

        h.server.start()
        #expect(await eventually { h.server.acceptLoopCountForTesting == 1 })
        let client = try await h.greetedClient()
        client.close()
        h.server.stop()
        #expect(await eventually { h.server.acceptLoopCountForTesting == 0 })
    }

    @Test func dispatchTimeoutAnswersWithoutWedgingTheConnection() async throws {
        let h = try makeHarness(configuration: .init(dispatchTimeout: .milliseconds(100)))
        defer { h.runtime.cleanup() }
        h.server.start()
        defer { h.server.stop() }
        let client = try await h.greetedClient()

        h.dispatcher.holdDispatch = true
        try await client.send("STATUS\n")
        #expect(try await client.readLine() == #"{"code":"timeout","error":"command timed out","ok":false}"#)
        #expect(h.dispatcher.commands == [.status])

        // The late result is dropped; the connection keeps serving.
        h.dispatcher.holdDispatch = false
        h.dispatcher.releaseHeldDispatches()
        try await client.send("DEVICES\n")
        #expect(try await client.readLine() == responseLine(seq: 1))
        #expect(h.dispatcher.commands == [.status, .devices])
        client.close()
    }

    // MARK: - AppState toggle wiring (no dispatch behavior involved)

    @Test func settingsToggleStartsAndStopsTheSocketAtTheInjectedPath() async throws {
        let runtime = try IsolatedTestRuntime()
        defer { runtime.cleanup() }
        SimulatedPositionPersistence.setRestoreOnLaunch(false, in: runtime.defaults)
        let app = AppState(defaults: runtime.defaults, runtimePaths: runtime.runtimePaths)
        let socketPath = runtime.runtimePaths.aiSocketURL.path
        #expect(socketPath.hasPrefix(runtime.rootDirectory.path + "/"))
        #expect(!app.aiControlEnabled)
        #expect(!FileManager.default.fileExists(atPath: socketPath))

        app.aiControlEnabled = true
        #expect(runtime.defaults.bool(forKey: "aiControlEnabled"))
        #expect(try fileType(at: socketPath) == .typeSocket)
        let client = try CommandSocketClient(path: socketPath)
        #expect(try await client.readLine() == Self.expectedGreeting)

        app.aiControlEnabled = false
        #expect(!runtime.defaults.bool(forKey: "aiControlEnabled"))
        #expect(!FileManager.default.fileExists(atPath: socketPath))
        #expect(try await client.awaitEOF())
        #expect(throws: CommandSocketClient.ClientError.connectFailed(errno: ENOENT)) {
            try CommandSocketClient(path: socketPath)
        }
        client.close()
        await app.prepareForQuit()
    }

    @Test func persistedToggleListensAtLaunchAndQuitUnlinksTheSocket() async throws {
        let runtime = try IsolatedTestRuntime()
        defer { runtime.cleanup() }
        SimulatedPositionPersistence.setRestoreOnLaunch(false, in: runtime.defaults)
        runtime.defaults.set(true, forKey: "aiControlEnabled")

        let app = AppState(defaults: runtime.defaults, runtimePaths: runtime.runtimePaths)
        let socketPath = runtime.runtimePaths.aiSocketURL.path
        #expect(app.aiControlEnabled)
        #expect(try fileType(at: socketPath) == .typeSocket)
        let client = try CommandSocketClient(path: socketPath)
        #expect(try await client.readLine() == Self.expectedGreeting)

        await app.prepareForQuit()
        #expect(!FileManager.default.fileExists(atPath: socketPath))
        #expect(try await client.awaitEOF())
        client.close()
    }
}
