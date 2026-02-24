import ArgumentParser
import Foundation

/// Query the running daemon for its current status and preloaded models.
struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show daemon status and preloaded models"
    )

    @Option(help: "Unix domain socket path")
    var socket: String = DaemonDefaults.socketPath

    @Flag(name: .long, help: "Output as JSON")
    var json: Bool = false

    func run() throws {
        let socketExists = FileManager.default.fileExists(atPath: socket)

        guard socketExists else {
            if json {
                printJSON(StatusOutput(running: false, socket: socket))
            } else {
                print("Daemon is not running (no socket at \(socket))")
            }
            throw ExitCode.failure
        }

        let semaphore = DispatchSemaphore(value: 0)
        var result: DaemonResponse?

        Task {
            result = await DaemonClient.send(.status(), socketPath: socket, timeout: 5)
            semaphore.signal()
        }
        semaphore.wait()

        guard let response = result else {
            if json {
                printJSON(StatusOutput(running: false, socket: socket,
                                       error: "not responding"))
            } else {
                print("Daemon is not responding (socket exists at \(socket) but connection failed)")
            }
            throw ExitCode.failure
        }

        guard response.ok else {
            let msg = response.error ?? "unknown error"
            if json {
                printJSON(StatusOutput(running: false, socket: socket, error: msg))
            } else {
                print("Daemon returned error: \(msg)")
            }
            throw ExitCode.failure
        }

        let models = response.models ?? []

        if json {
            printJSON(StatusOutput(
                running: true,
                socket: socket,
                activeModel: response.loaded,
                preloadedModels: models.sorted()
            ))
        } else {
            print("Daemon is running")
            print("  Socket: \(socket)")

            if let current = response.loaded {
                print("  Active model: \(current)")
            } else {
                print("  Active model: none")
            }

            if !models.isEmpty {
                print("  Preloaded models:")
                for model in models.sorted() {
                    let marker = model == response.loaded ? " (active)" : ""
                    print("    - \(model)\(marker)")
                }
            } else {
                print("  Preloaded models: none")
            }
        }
    }

    // MARK: - JSON output

    private struct StatusOutput: Encodable {
        let running: Bool
        let socket: String
        var error: String?
        var activeModel: String?
        var preloadedModels: [String]?
    }

    private func printJSON(_ value: StatusOutput) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value),
              let str = String(data: data, encoding: .utf8) else { return }
        print(str)
    }
}
