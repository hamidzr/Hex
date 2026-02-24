import Foundation
import Network
import WhisperKit

/// Long-lived daemon that keeps WhisperKit models loaded in memory and serves
/// transcription requests over a Unix domain socket.
final class DaemonServer: @unchecked Sendable {
    private let socketPath: String
    private let language: String
    private var listener: NWListener?
    private let transcription = CLITranscriptionClient()
    private let requestQueue = DispatchQueue(label: "hex-daemon.requests")
    private let listenerQueue = DispatchQueue(label: "hex-daemon.listener")

    init(socketPath: String, language: String) {
        self.socketPath = socketPath
        self.language = language
    }

    // MARK: - Lifecycle

    func start() throws {
        // clean up stale socket
        unlink(socketPath)

        // ensure parent directory exists
        let dir = (socketPath as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(
            atPath: dir, withIntermediateDirectories: true)

        let params = NWParameters()
        params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()
        params.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)

        listener = try NWListener(using: params)

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("Daemon listening on \(self.socketPath)")
            case .failed(let error):
                print("Listener failed: \(error)")
            default:
                break
            }
        }

        listener?.start(queue: listenerQueue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        unlink(socketPath)
    }

    /// Preload models into memory so first transcription is instant.
    func preloadModels(_ models: [String]) async {
        for model in models {
            print("Preloading \(model)...")
            let start = Date()
            do {
                try await transcription.downloadModel(model) { _ in }
                let elapsed = Date().timeIntervalSince(start)
                print("  \(model) ready (\(String(format: "%.1f", elapsed))s)")
            } catch {
                print("  Failed to preload \(model): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Connection handling

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: requestQueue)

        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, _, error in
            guard let self, let data, !data.isEmpty else {
                connection.cancel()
                return
            }

            Task {
                let response = await self.processRequest(data: data)
                self.sendResponse(response, on: connection)
            }
        }
    }

    private func sendResponse(_ response: DaemonResponse, on connection: NWConnection) {
        do {
            let data = try DaemonWire.encode(response)
            connection.send(content: data, completion: .contentProcessed { _ in
                connection.cancel()
            })
        } catch {
            connection.cancel()
        }
    }

    // MARK: - Request dispatch (serialized via actor)

    private func processRequest(data: Data) async -> DaemonResponse {
        let request: DaemonRequest
        do {
            request = try DaemonWire.decodeRequest(from: data)
        } catch {
            return .error("Invalid request: \(error.localizedDescription)")
        }

        switch request.action {
        case .transcribe:
            return await handleTranscribe(request)
        case .status:
            return await handleStatus()
        case .preload:
            return await handlePreload(request)
        }
    }

    private func handleTranscribe(_ request: DaemonRequest) async -> DaemonResponse {
        guard let audioPath = request.audio else {
            return .error("Missing 'audio' field")
        }
        guard let model = request.model else {
            return .error("Missing 'model' field")
        }

        let url = URL(fileURLWithPath: audioPath)
        guard FileManager.default.fileExists(atPath: audioPath) else {
            return .error("Audio file not found: \(audioPath)")
        }

        let lang = request.language ?? language
        let options = DecodingOptions(
            language: lang,
            detectLanguage: false
        )

        let start = Date()
        do {
            let text = try await transcription.transcribe(url, model, options) { _ in }
            let elapsed = Date().timeIntervalSince(start)
            return .success(text: text, seconds: elapsed)
        } catch {
            return .error("Transcription failed: \(error.localizedDescription)")
        }
    }

    private func handleStatus() async -> DaemonResponse {
        let loaded = await transcription.loadedModels()
        let current = await transcription.currentModel()
        return .status(models: loaded, loaded: current)
    }

    private func handlePreload(_ request: DaemonRequest) async -> DaemonResponse {
        guard let model = request.model else {
            return .error("Missing 'model' field")
        }
        do {
            try await transcription.downloadModel(model) { _ in }
            return .status(models: await transcription.loadedModels(),
                           loaded: await transcription.currentModel())
        } catch {
            return .error("Preload failed: \(error.localizedDescription)")
        }
    }
}
