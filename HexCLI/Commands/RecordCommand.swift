import AppKit
import ArgumentParser
import Foundation
import WhisperKit

/// Default subcommand: record from microphone and transcribe (existing behavior).
struct RecordCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "Record from microphone and transcribe"
    )

    @Option(
        name: .shortAndLong,
        help: "Duration to record in seconds (default: record until stopped)")
    var duration: Double?

    @Option(name: .shortAndLong, help: "Output file path (default: stdout)")
    var output: String?

    @Option(name: .shortAndLong, help: "Whisper model to use")
    var model: String = "distil-whisper_distil-large-v3_turbo"

    @Option(name: .shortAndLong, help: "Language code for transcription (default: auto-detect)")
    var language: String?

    @Flag(name: .shortAndLong, help: "Copy result to clipboard")
    var clipboard: Bool = false

    @Flag(name: .shortAndLong, help: "Verbose output")
    var verbose: Bool = false

    @Flag(name: .shortAndLong, help: "Silent mode - only output transcription result")
    var silent: Bool = false

    @Option(help: "Audio input device ID (default: system default)")
    var inputDevice: String?

    @Flag(help: "List available audio input devices")
    var listDevices: Bool = false

    @Flag(help: "List available Whisper models")
    var listModels: Bool = false

    func run() throws {
        if listDevices {
            listAudioDevicesSync()
            return
        }

        if listModels {
            listWhisperModelsSync()
            return
        }

        let runLoop = RunLoop.current
        var transcriptionError: Error?
        var isCompleted = false

        Task {
            do {
                try await performTranscription()
            } catch {
                transcriptionError = error
            }
            isCompleted = true
            CFRunLoopStop(runLoop.getCFRunLoop())
        }

        while !isCompleted && !SignalHandler.shared.checkShouldSkipTranscription() {
            runLoop.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }

        if let error = transcriptionError {
            throw error
        }
    }

    private func performTranscription() async throws {
        let recorder = CLIRecordingClient()
        let transcription = CLITranscriptionClient()

        SignalHandler.shared.setSilent(silent)

        let hasPermission = await recorder.requestMicrophoneAccess()
        guard hasPermission else {
            throw CLIError.microphonePermissionDenied
        }

        if let deviceID = inputDevice {
            try await recorder.setInputDevice(deviceID)
        }

        if verbose && !silent {
            print("Checking model availability...")
        }

        let isDownloaded = await transcription.isModelDownloaded(model)
        if !isDownloaded {
            if !silent {
                print("Downloading model '\(model)'...")
            }
            try await transcription.downloadModel(model) { progress in
                if verbose && !silent {
                    print("Download progress: \(Int(progress.fractionCompleted * 100))%")
                }
            }
        }

        if !silent {
            print("Recording... (Press Ctrl+C to exit, or send SIGHUP to transcribe)")
        }

        SignalHandler.shared.reset()
        await recorder.startRecording()

        if let duration = duration {
            let endTime = Date().addingTimeInterval(duration)
            while Date() < endTime && !SignalHandler.shared.checkShouldStop() {
                try await Task.sleep(for: .milliseconds(50))
            }
        } else {
            while !SignalHandler.shared.checkShouldStop() {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        let audioURL = await recorder.stopRecording()

        if SignalHandler.shared.checkShouldSkipTranscription() {
            if !silent {
                print("Skipping transcription as requested")
            }
            try? FileManager.default.removeItem(at: audioURL)
            return
        }

        if !silent {
            print("Transcribing...")
        }

        let decodeOptions = DecodingOptions(
            language: language,
            detectLanguage: language == nil
        )

        let result = try await transcription.transcribe(audioURL, model, decodeOptions) {
            progress in
            if verbose && !silent {
                print("Transcription progress: \(Int(progress.fractionCompleted * 100))%")
            }
        }

        try outputResult(result)
        try? FileManager.default.removeItem(at: audioURL)
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

    private func listAudioDevicesSync() {
        if !silent {
            print("Available audio input devices:")
        }
        let devices = AudioDeviceHelpers.getAllAudioDevices()
        for device in devices {
            if AudioDeviceHelpers.deviceHasInput(deviceID: device),
                let name = AudioDeviceHelpers.getDeviceName(deviceID: device)
            {
                print("  \(device): \(name)")
            }
        }
    }

    private func listWhisperModelsSync() {
        if !silent {
            print("Available Whisper models:")
        }
        let commonModels = [
            "openai_whisper-tiny",
            "openai_whisper-tiny.en",
            "openai_whisper-base",
            "openai_whisper-base.en",
            "openai_whisper-small",
            "openai_whisper-small.en",
            "openai_whisper-medium",
            "openai_whisper-medium.en",
            "openai_whisper-large-v2",
            "openai_whisper-large-v3",
            "openai_whisper-large-v3-v20240930",
            "openai_whisper-large-v3-v20240930_turbo",
            "distil-whisper_distil-large-v3_turbo",
        ]
        for model in commonModels {
            print("  \(model)")
        }
        if !silent {
            print("\nNote: Models will be downloaded automatically when first used.")
        }
    }
}
