import Foundation
import Network
import XCTest

@testable import HexCLI

final class DaemonServerTests: XCTestCase {
    private var server: DaemonServer!
    private var socketPath: String!

    override func setUp() {
        super.setUp()
        // use a unique socket per test to avoid conflicts
        socketPath = "/tmp/hex-test-\(UUID().uuidString.prefix(8)).sock"
        server = DaemonServer(socketPath: socketPath, language: "en")
    }

    override func tearDown() {
        server.stop()
        unlink(socketPath)
        super.tearDown()
    }

    // MARK: - Server lifecycle

    func testServerStartsAndAcceptsConnection() async throws {
        try server.start()

        // give the listener a moment to bind
        try await Task.sleep(for: .milliseconds(100))

        // send a status request
        let response = await DaemonClient.send(
            .status(), socketPath: socketPath, timeout: 5)

        XCTAssertNotNil(response, "should get a response from daemon")
        XCTAssertTrue(response!.ok)
        XCTAssertNotNil(response!.models)
    }

    func testServerReturnsErrorForMissingAudioFile() async throws {
        try server.start()
        try await Task.sleep(for: .milliseconds(100))

        let request = DaemonRequest.transcribe(
            audio: "/nonexistent/file.wav",
            model: "openai_whisper-tiny.en",
            language: "en"
        )
        let response = await DaemonClient.send(
            request, socketPath: socketPath, timeout: 5)

        XCTAssertNotNil(response)
        XCTAssertFalse(response!.ok)
        XCTAssertNotNil(response!.error)
        XCTAssertTrue(response!.error!.contains("not found"))
    }

    func testServerReturnsErrorForMissingFields() async throws {
        try server.start()
        try await Task.sleep(for: .milliseconds(100))

        // transcribe request with no audio path
        let request = DaemonRequest(
            action: .transcribe, audio: nil, model: "tiny", language: nil)
        let response = await DaemonClient.send(
            request, socketPath: socketPath, timeout: 5)

        XCTAssertNotNil(response)
        XCTAssertFalse(response!.ok)
        XCTAssertTrue(response!.error!.contains("audio"))
    }

    func testServerReturnsErrorForTranscribeWithoutModel() async throws {
        try server.start()
        try await Task.sleep(for: .milliseconds(100))

        let request = DaemonRequest(
            action: .transcribe, audio: "/tmp/test.wav", model: nil, language: nil)
        let response = await DaemonClient.send(
            request, socketPath: socketPath, timeout: 5)

        XCTAssertNotNil(response)
        XCTAssertFalse(response!.ok)
        XCTAssertTrue(response!.error!.contains("model"))
    }

    func testServerHandlesInvalidJSON() async throws {
        try server.start()
        try await Task.sleep(for: .milliseconds(100))

        // send raw garbage over the socket
        let response = await sendRawAndReceive("not json at all\n")

        XCTAssertNotNil(response)
        XCTAssertFalse(response!.ok)
        XCTAssertTrue(response!.error!.contains("Invalid request"))
    }

    func testServerStopCleansUpSocket() async throws {
        try server.start()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))

        server.stop()
        // socket file should be removed
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
    }

    func testMultipleStatusRequests() async throws {
        try server.start()
        try await Task.sleep(for: .milliseconds(100))

        // send several requests sequentially
        for _ in 0..<5 {
            let response = await DaemonClient.send(
                .status(), socketPath: socketPath, timeout: 5)
            XCTAssertNotNil(response)
            XCTAssertTrue(response!.ok)
        }
    }

    // MARK: - Client behavior

    func testClientReturnsNilWhenDaemonNotRunning() async {
        let response = await DaemonClient.send(
            .status(), socketPath: "/tmp/nonexistent-socket.sock", timeout: 2)
        XCTAssertNil(response)
    }

    func testClientIsRunningReturnsFalseWhenDown() async {
        let result = await DaemonClient.isRunning(
            socketPath: "/tmp/nonexistent-socket.sock")
        XCTAssertFalse(result)
    }

    func testClientIsRunningReturnsTrueWhenUp() async throws {
        try server.start()
        try await Task.sleep(for: .milliseconds(100))

        let result = await DaemonClient.isRunning(socketPath: socketPath)
        XCTAssertTrue(result)
    }

    // MARK: - Helpers

    /// Send raw bytes over the socket and decode the response.
    private func sendRawAndReceive(_ rawString: String) async -> DaemonResponse? {
        await withCheckedContinuation { continuation in
            let endpoint = NWEndpoint.unix(path: socketPath)
            let params = NWParameters()
            params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
            let connection = NWConnection(to: endpoint, using: params)
            let queue = DispatchQueue(label: "hex-test.raw-client")
            let resumed = LockedBool()

            func resumeOnce(_ value: DaemonResponse?) {
                guard resumed.testAndSet() else { return }
                continuation.resume(returning: value)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    let data = rawString.data(using: .utf8)!
                    connection.send(content: data, completion: .contentProcessed { _ in
                        connection.receive(
                            minimumIncompleteLength: 1, maximumLength: 65536
                        ) { data, _, _, _ in
                            connection.cancel()
                            guard let data else {
                                resumeOnce(nil)
                                return
                            }
                            let resp = try? DaemonWire.decodeResponse(from: data)
                            resumeOnce(resp)
                        }
                    })
                case .failed, .cancelled:
                    resumeOnce(nil)
                default:
                    break
                }
            }
            connection.start(queue: queue)
        }
    }
}

// MARK: - Thread-safe bool for continuation guard

private final class LockedBool: @unchecked Sendable {
    private var value = false
    private let lock = NSLock()

    /// Returns true on the first call, false on subsequent calls.
    func testAndSet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if value { return false }
        value = true
        return true
    }
}
