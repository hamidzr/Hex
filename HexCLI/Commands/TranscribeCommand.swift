import AppKit
import ArgumentParser
import Foundation
import WhisperKit

/// Transcribe an audio file directly (one-shot, no recording).
struct TranscribeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "transcribe",
        abstract: "Transcribe an audio file"
    )

    @Argument(help: "Path to audio file to transcribe")
    var audioFile: String

    @Option(name: .shortAndLong, help: "Whisper model to use")
    var model: String = "distil-whisper_distil-large-v3_turbo"

    @Option(name: .shortAndLong, help: "Language code for transcription")
    var language: String = "en"

    @Option(name: .shortAndLong, help: "Output file path (default: stdout)")
    var output: String?

    @Flag(name: .shortAndLong, help: "Copy result to clipboard")
    var clipboard: Bool = false

    @Flag(name: .shortAndLong, help: "Silent mode - only output transcription result")
    var silent: Bool = false

    @Flag(help: "Use daemon if available (fall back to local)")
    var daemon: Bool = false

    @Option(help: "Daemon socket path")
    var socket: String = DaemonDefaults.socketPath

    func run() throws {
        let runLoop = RunLoop.current
        var commandError: Error?
        var isCompleted = false

        Task {
            do {
                try await performTranscription()
            } catch {
                commandError = error
            }
            isCompleted = true
            CFRunLoopStop(runLoop.getCFRunLoop())
        }

        while !isCompleted {
            runLoop.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }

        if let error = commandError {
            throw error
        }
    }

    private func performTranscription() async throws {
        let url = URL(fileURLWithPath: audioFile)
        guard FileManager.default.fileExists(atPath: audioFile) else {
            throw ValidationError("Audio file not found: \(audioFile)")
        }

        // try daemon first if requested
        if daemon {
            let request = DaemonRequest.transcribe(
                audio: url.path, model: model, language: language)
            if let response = await DaemonClient.send(request, socketPath: socket) {
                if response.ok, let text = response.text {
                    try outputResult(text)
                    return
                } else if let error = response.error {
                    if !silent {
                        print("Daemon error: \(error), falling back to local transcription...")
                    }
                }
            } else if !silent {
                print("Daemon not available, using local transcription...")
            }
        }

        // local transcription
        let transcription = CLITranscriptionClient()

        let decodeOptions = DecodingOptions(
            language: language,
            detectLanguage: false
        )

        if !silent {
            print("Transcribing \(audioFile)...")
        }

        let result = try await transcription.transcribe(url, model, decodeOptions) { _ in }

        try outputResult(result)
    }

    private func outputResult(_ text: String) throws {
        if let outputPath = output {
            try text.write(toFile: outputPath, atomically: true, encoding: .utf8)
            if !silent {
                print("Transcription saved to: \(outputPath)")
            }
        } else {
            if silent {
                print(text)
            } else {
                print("Transcription:")
                print(text)
            }
        }

        if clipboard {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: .string)
            if !silent {
                print("Copied to clipboard")
            }
        }
    }
}
