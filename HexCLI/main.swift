import AVFoundation
import AppKit
import ArgumentParser
import CoreAudio
import Foundation
import WhisperKit

// MARK: - Signal Handling

class SignalHandler {
    static let shared = SignalHandler()
    private var shouldStop = false
    private var shouldSkipTranscription = false
    private let queue = DispatchQueue(label: "signal-handler")

    // Keep references to prevent deallocation
    private var sigintSource: DispatchSourceSignal?
    private var sighupSource: DispatchSourceSignal?
    private var sigtermSource: DispatchSourceSignal?

    private init() {
        setupSignalHandlers()
    }

    private func setupSignalHandlers() {
        let signalQueue = DispatchQueue(label: "signal-queue")

        // Handle SIGINT (Ctrl+C) - stops recording and exits without transcription
        sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: signalQueue)
        sigintSource?.setEventHandler { [weak self] in
            print("\n🛑 Received SIGINT (Ctrl+C), stopping without transcription...")
            self?.stopWithoutTranscription()
        }
        sigintSource?.resume()

        // Handle SIGHUP - stops recording and transcribes what was recorded
        sighupSource = DispatchSource.makeSignalSource(signal: SIGHUP, queue: signalQueue)
        sighupSource?.setEventHandler { [weak self] in
            print("\n🎙️ Received SIGHUP, stopping recording and transcribing...")
            self?.stop()
        }
        sighupSource?.resume()

        // Handle SIGTERM (termination signal) - for clean shutdown
        sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: signalQueue)
        sigtermSource?.setEventHandler { [weak self] in
            print("\n🛑 Received SIGTERM, stopping...")
            self?.stop()
        }
        sigtermSource?.resume()

        // Prevent default signal handlers for the signals we handle
        signal(SIGINT, SIG_IGN)
        signal(SIGHUP, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
    }

    func stop() {
        queue.sync {
            shouldStop = true
        }
    }

    func stopWithoutTranscription() {
        queue.sync {
            shouldStop = true
            shouldSkipTranscription = true
        }
    }

    func reset() {
        queue.sync {
            shouldStop = false
            shouldSkipTranscription = false
        }
    }

    func checkShouldStop() -> Bool {
        return queue.sync {
            return shouldStop
        }
    }

    func checkShouldSkipTranscription() -> Bool {
        return queue.sync {
            return shouldSkipTranscription
        }
    }

    deinit {
        sigintSource?.cancel()
        sighupSource?.cancel()
        sigtermSource?.cancel()
    }
}

// MARK: - CLI Configuration

struct HexCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hex-cli",
        abstract: "Command-line voice-to-text transcription using Whisper",
        version: "1.0.0"
    )

    @Option(
        name: .shortAndLong, help: "Duration to record in seconds (default: record until stopped)")
    var duration: Double?

    @Option(name: .shortAndLong, help: "Output file path (default: stdout)")
    var output: String?

    @Option(name: .shortAndLong, help: "Whisper model to use")
    var model: String = "openai_whisper-large-v3-v20240930"

    @Option(name: .shortAndLong, help: "Language code for transcription (default: auto-detect)")
    var language: String?

    @Flag(name: .shortAndLong, help: "Copy result to clipboard")
    var clipboard: Bool = false

    @Flag(name: .shortAndLong, help: "Verbose output")
    var verbose: Bool = false

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

        // For transcription, we need to run async code
        // Use RunLoop to keep the main thread responsive for signal handling
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
            // Wake up the run loop
            CFRunLoopStop(runLoop.getCFRunLoop())
        }

        // Keep the run loop running until transcription is complete
        // Only exit early if we should skip transcription (Ctrl+C)
        while !isCompleted && !SignalHandler.shared.checkShouldSkipTranscription() {
            runLoop.run(mode: .default, before: Date(timeIntervalSinceNow: 0.1))
        }

        if let error = transcriptionError {
            throw error
        }
    }

    func listAudioDevicesSync() {
        print("Available audio input devices:")

        // Simplified device listing
        let devices = getAllAudioDevices()
        for device in devices {
            if deviceHasInput(deviceID: device),
                let name = getDeviceName(deviceID: device)
            {
                print("  \(device): \(name)")
            }
        }
    }

    func listWhisperModelsSync() {
        print("Available Whisper models:")

        // Common Whisper models
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
        ]

        for model in commonModels {
            print("  ⬇️ \(model)")
        }

        print("\nNote: Models will be downloaded automatically when first used.")
    }
}

// MARK: - Core Functionality

extension HexCLI {
    func performTranscription() async throws {
        let recorder = CLIRecordingClient()
        let transcription = CLITranscriptionClient()

        // Request microphone permission
        let hasPermission = await recorder.requestMicrophoneAccess()
        guard hasPermission else {
            throw CLIError.microphonePermissionDenied
        }

        // Setup input device if specified
        if let deviceID = inputDevice {
            try await recorder.setInputDevice(deviceID)
        }

        // Download model if needed
        if verbose {
            print("Checking model availability...")
        }

        let isDownloaded = await transcription.isModelDownloaded(model)
        if !isDownloaded {
            print("Downloading model '\(model)'...")
            try await transcription.downloadModel(model) { progress in
                if verbose {
                    print("Download progress: \(Int(progress.fractionCompleted * 100))%")
                }
            }
        }

        // Start recording
        print("🎤 Recording... (Press Ctrl+C to exit, or send SIGHUP to transcribe)")

        let audioURL = try await performRecording(recorder: recorder)

        // Check if we should skip transcription (Ctrl+C was pressed)
        if SignalHandler.shared.checkShouldSkipTranscription() {
            print("🚫 Skipping transcription as requested")
            try? FileManager.default.removeItem(at: audioURL)
            return
        }

        // Transcribe
        print("🔄 Transcribing...")

        let decodeOptions = DecodingOptions(
            language: language,
            detectLanguage: language == nil
        )

        let result = try await transcription.transcribe(audioURL, model, decodeOptions) {
            progress in
            if verbose {
                print("Transcription progress: \(Int(progress.fractionCompleted * 100))%")
            }
        }

        // Output result
        try await outputResult(result)

        // Cleanup
        try? FileManager.default.removeItem(at: audioURL)
    }

    func performRecording(recorder: CLIRecordingClient) async throws -> URL {
        SignalHandler.shared.reset()
        await recorder.startRecording()

        if let duration = duration {
            // Record for specified duration, but still check for stop signal
            let endTime = Date().addingTimeInterval(duration)
            while Date() < endTime && !SignalHandler.shared.checkShouldStop() {
                try await Task.sleep(for: .milliseconds(50))
            }
        } else {
            // Record until interrupted
            await waitForStopSignal()
        }

        return await recorder.stopRecording()
    }

    func waitForStopSignal() async {
        // Poll for stop signal every 50ms for better responsiveness
        while !SignalHandler.shared.checkShouldStop() {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    func outputResult(_ text: String) async throws {
        if let outputPath = output {
            try text.write(toFile: outputPath, atomically: true, encoding: .utf8)
            print("✅ Transcription saved to: \(outputPath)")
        } else {
            print("📝 Transcription:")
            print(text)
        }

        if clipboard {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(text, forType: NSPasteboard.PasteboardType.string)
            print("📋 Copied to clipboard")
        }
    }

    func listAudioDevices() async throws {
        print("Available audio input devices:")

        // Simplified device listing
        let devices = getAllAudioDevices()
        for device in devices {
            if deviceHasInput(deviceID: device),
                let name = getDeviceName(deviceID: device)
            {
                print("  \(device): \(name)")
            }
        }
    }

    // Helper methods for audio device enumeration
    private func getAllAudioDevices() -> [AudioDeviceID] {
        var propertySize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &propertySize
            ) == 0
        else { return [] }

        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &propertySize,
                &deviceIDs
            ) == 0
        else { return [] }

        return deviceIDs
    }

    private func deviceHasInput(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &propertySize) == 0 else {
            return false
        }

        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(propertySize))
        defer { bufferList.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, bufferList) == 0
        else {
            return false
        }

        let buffersPointer = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffersPointer.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private func getDeviceName(deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == 0 else {
            return nil
        }

        var deviceName: CFString?
        let deviceNamePtr = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
        defer { deviceNamePtr.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, deviceNamePtr) == 0
        else {
            return nil
        }

        deviceName = deviceNamePtr.pointee
        return deviceName as String?
    }

    func listWhisperModels() async throws {
        print("Available Whisper models:")

        // Common Whisper models
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
        ]

        for model in commonModels {
            print("  ⬇️ \(model)")
        }

        print("\nNote: Models will be downloaded automatically when first used.")
    }
}

// MARK: - CLI-Specific Clients

actor CLIRecordingClient {
    private var recorder: AVAudioRecorder?
    private let recordingURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "hex-cli-recording.wav")

    func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func setInputDevice(_ deviceID: String) async throws {
        // Implementation similar to RecordingClient but simplified for CLI
        guard let audioDeviceID = AudioDeviceID(deviceID) else {
            throw CLIError.invalidInputDevice
        }

        // Set as default input device (simplified version)
        var device = audioDeviceID
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            size,
            &device
        )

        if status != 0 {
            throw CLIError.failedToSetInputDevice
        }
    }

    func startRecording() async {
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]

        do {
            recorder = try AVAudioRecorder(url: recordingURL, settings: settings)
            recorder?.record()
        } catch {
            print("Could not start recording: \(error)")
        }
    }

    func stopRecording() async -> URL {
        recorder?.stop()
        recorder = nil
        return recordingURL
    }

    func getAvailableInputDevices() async -> [AudioInputDevice] {
        // Simplified version of the device enumeration from RecordingClient
        let devices = getAllAudioDevices()
        var inputDevices: [AudioInputDevice] = []

        for device in devices {
            if deviceHasInput(deviceID: device),
                let name = getDeviceName(deviceID: device)
            {
                inputDevices.append(AudioInputDevice(id: String(device), name: name))
            }
        }

        return inputDevices
    }

    // Helper methods (simplified from RecordingClient)
    private func getAllAudioDevices() -> [AudioDeviceID] {
        var propertySize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &propertySize
            ) == 0
        else { return [] }

        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                0,
                nil,
                &propertySize,
                &deviceIDs
            ) == 0
        else { return [] }

        return deviceIDs
    }

    private func deviceHasInput(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        var propertySize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &propertySize) == 0 else {
            return false
        }

        let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(propertySize))
        defer { bufferList.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &propertySize, bufferList) == 0
        else {
            return false
        }

        let buffersPointer = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffersPointer.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private func getDeviceName(deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == 0 else {
            return nil
        }

        var deviceName: CFString?
        let deviceNamePtr = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
        defer { deviceNamePtr.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, deviceNamePtr) == 0
        else {
            return nil
        }

        deviceName = deviceNamePtr.pointee
        return deviceName as String?
    }
}

actor CLITranscriptionClient {
    private var whisperKit: WhisperKit?
    private var currentModelName: String?

    private lazy var modelsBaseFolder: URL = {
        let appSupportURL = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let ourAppFolder = appSupportURL.appendingPathComponent(
            "com.kitlangton.HexCLI", isDirectory: true)
        let baseURL = ourAppFolder.appendingPathComponent("models", isDirectory: true)
        try? FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        return baseURL
    }()

    func downloadModel(_ variant: String, progressCallback: @escaping (Progress) -> Void)
        async throws
    {
        let overallProgress = Progress(totalUnitCount: 100)

        if !(await isModelDownloaded(variant)) {
            try await downloadModelIfNeeded(variant: variant) { downloadProgress in
                let fraction = downloadProgress.fractionCompleted * 0.5
                overallProgress.completedUnitCount = Int64(fraction * 100)
                progressCallback(overallProgress)
            }
        } else {
            overallProgress.completedUnitCount = 50
            progressCallback(overallProgress)
        }

        try await loadWhisperKitModel(variant) { loadingProgress in
            let fraction = 0.5 + (loadingProgress.fractionCompleted * 0.5)
            overallProgress.completedUnitCount = Int64(fraction * 100)
            progressCallback(overallProgress)
        }

        overallProgress.completedUnitCount = 100
        progressCallback(overallProgress)
    }

    func isModelDownloaded(_ variant: String) async -> Bool {
        let modelFolder = modelPath(for: variant)
        let tokenizerFolder = tokenizerPath(for: variant)

        return FileManager.default.fileExists(atPath: modelFolder.path)
            && FileManager.default.fileExists(atPath: tokenizerFolder.path)
    }

    func transcribe(
        _ url: URL, _ model: String, _ options: DecodingOptions,
        progressCallback: @escaping (Progress) -> Void
    ) async throws -> String {
        if whisperKit == nil || model != currentModelName {
            try await downloadModel(model, progressCallback: progressCallback)
        }

        guard let whisperKit = whisperKit else {
            throw CLIError.transcriptionFailed
        }

        let results = try await whisperKit.transcribe(audioPath: url.path, decodeOptions: options)
        return results.map { $0.text }.joined(separator: " ")
    }

    func getAvailableModels() async throws -> [String] {
        try await WhisperKit.fetchAvailableModels()
    }

    // Private helper methods (adapted from TranscriptionClient)
    private func modelPath(for variant: String) -> URL {
        let sanitizedVariant = variant.replacingOccurrences(of: "/", with: "_")
        return modelsBaseFolder.appendingPathComponent(sanitizedVariant, isDirectory: true)
    }

    private func tokenizerPath(for variant: String) -> URL {
        return modelPath(for: variant).appendingPathComponent("tokenizer.json")
    }

    private func downloadModelIfNeeded(
        variant: String, progressCallback: @escaping (Progress) -> Void
    ) async throws {
        let modelFolder = modelPath(for: variant)

        if await isModelDownloaded(variant) {
            return
        }

        let tempFolder = try await WhisperKit.download(
            variant: variant,
            downloadBase: nil,
            useBackgroundSession: false,
            from: "argmaxinc/whisperkit-coreml",
            token: nil,
            progressCallback: progressCallback
        )

        try FileManager.default.createDirectory(at: modelFolder, withIntermediateDirectories: true)
        try moveContents(of: tempFolder, to: modelFolder)
    }

    private func loadWhisperKitModel(
        _ modelName: String, progressCallback: @escaping (Progress) -> Void
    ) async throws {
        let loadingProgress = Progress(totalUnitCount: 100)
        progressCallback(loadingProgress)

        let modelFolder = modelPath(for: modelName)
        let tokenizerFolder = tokenizerPath(for: modelName)

        let config = WhisperKitConfig(
            model: modelName,
            modelFolder: modelFolder.path,
            tokenizerFolder: tokenizerFolder,
            prewarm: true,
            load: true
        )

        whisperKit = try await WhisperKit(config)
        currentModelName = modelName

        loadingProgress.completedUnitCount = 100
        progressCallback(loadingProgress)
    }

    private func moveContents(of sourceFolder: URL, to destFolder: URL) throws {
        let fileManager = FileManager.default
        let items = try fileManager.contentsOfDirectory(atPath: sourceFolder.path)
        for item in items {
            let src = sourceFolder.appendingPathComponent(item)
            let dst = destFolder.appendingPathComponent(item)
            try fileManager.moveItem(at: src, to: dst)
        }
    }
}

// MARK: - Supporting Types

struct AudioInputDevice {
    let id: String
    let name: String
}

// MARK: - Error Handling

enum CLIError: Error, LocalizedError {
    case microphonePermissionDenied
    case invalidInputDevice
    case failedToSetInputDevice
    case transcriptionFailed

    var errorDescription: String? {
        switch self {
        case .microphonePermissionDenied:
            return "Microphone permission denied. Please grant access in System Preferences."
        case .invalidInputDevice:
            return "Invalid input device ID specified."
        case .failedToSetInputDevice:
            return "Failed to set the specified input device."
        case .transcriptionFailed:
            return "Transcription failed. Please check your model and try again."
        }
    }
}

// MARK: - Main Entry Point

HexCLI.main()
