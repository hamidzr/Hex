import ArgumentParser
import Foundation

/// Run as a background daemon with models preloaded in memory.
struct DaemonCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Run as a background daemon with preloaded models"
    )

    @Option(help: "Unix domain socket path")
    var socket: String = DaemonDefaults.socketPath

    @Option(
        name: .long,
        parsing: .upToNextOption,
        help: "Models to preload at startup (repeatable)")
    var preload: [String] = DaemonDefaults.defaultPreload

    @Option(name: .shortAndLong, help: "Default language for transcription")
    var language: String = "en"

    func run() throws {
        let server = DaemonServer(socketPath: socket, language: language)

        print("hex-cli daemon starting...")
        print("  Socket: \(socket)")
        print("  Preload: \(preload.joined(separator: ", "))")
        print("  Language: \(language)")

        // set up signal handling for graceful shutdown
        let shutdownSource = DispatchSource.makeSignalSource(
            signal: SIGTERM, queue: .main)
        shutdownSource.setEventHandler {
            print("\nShutting down daemon...")
            server.stop()
            Foundation.exit(0)
        }
        shutdownSource.resume()
        signal(SIGTERM, SIG_IGN)

        let intSource = DispatchSource.makeSignalSource(
            signal: SIGINT, queue: .main)
        intSource.setEventHandler {
            print("\nShutting down daemon...")
            server.stop()
            Foundation.exit(0)
        }
        intSource.resume()
        signal(SIGINT, SIG_IGN)

        // start listener
        do {
            try server.start()
        } catch {
            print("Failed to start daemon: \(error.localizedDescription)")
            throw ExitCode.failure
        }

        // preload models asynchronously, then announce readiness
        Task {
            await server.preloadModels(preload)
            print("Daemon ready.")
        }

        // run forever
        dispatchMain()
    }
}
