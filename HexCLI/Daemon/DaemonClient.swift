import Foundation
import Network

/// Connects to a running hex daemon over a Unix domain socket, sends a request,
/// and returns the response. Designed for one-shot use.
enum DaemonClient {
    /// Send a request to the daemon and wait for a response.
    /// Returns nil if the daemon is not running or the connection fails.
    static func send(
        _ request: DaemonRequest,
        socketPath: String = DaemonDefaults.socketPath,
        timeout: TimeInterval = 120
    ) async -> DaemonResponse? {
        let requestData: Data
        do {
            requestData = try DaemonWire.encode(request)
        } catch {
            return nil
        }

        return await withCheckedContinuation { continuation in
            let endpoint = NWEndpoint.unix(path: socketPath)
            let params = NWParameters()
            params.defaultProtocolStack.transportProtocol = NWProtocolTCP.Options()

            let connection = NWConnection(to: endpoint, using: params)
            let queue = DispatchQueue(label: "hex-daemon.client")
            var completed = false

            let complete = { (response: DaemonResponse?) in
                guard !completed else { return }
                completed = true
                connection.cancel()
                continuation.resume(returning: response)
            }

            // timeout
            queue.asyncAfter(deadline: .now() + timeout) {
                complete(nil)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    // connected, send request
                    connection.send(content: requestData, completion: .contentProcessed { error in
                        if error != nil {
                            complete(nil)
                            return
                        }
                        // read response
                        connection.receive(
                            minimumIncompleteLength: 1, maximumLength: 1_048_576
                        ) { data, _, _, recvError in
                            guard let data, recvError == nil else {
                                complete(nil)
                                return
                            }
                            let response = try? DaemonWire.decodeResponse(from: data)
                            complete(response)
                        }
                    })
                case .failed, .cancelled:
                    complete(nil)
                default:
                    break
                }
            }

            connection.start(queue: queue)
        }
    }

    /// Check if the daemon is reachable.
    static func isRunning(socketPath: String = DaemonDefaults.socketPath) async -> Bool {
        guard FileManager.default.fileExists(atPath: socketPath) else { return false }
        let response = await send(.status(), socketPath: socketPath, timeout: 2)
        return response?.ok == true
    }
}
