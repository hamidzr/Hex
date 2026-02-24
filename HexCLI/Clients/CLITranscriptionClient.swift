import Foundation
import WhisperKit

actor CLITranscriptionClient {
    private var whisperKit: WhisperKit?
    private var currentModelName: String?
    private var preloadedModels: Set<String> = []

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

    // MARK: - Public API

    func downloadModel(_ variant: String, progressCallback: @escaping (Progress) -> Void)
        async throws
    {
        let overallProgress = Progress(totalUnitCount: 100)

        if !(isModelDownloaded(variant)) {
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

    func isModelDownloaded(_ variant: String) -> Bool {
        let modelFolder = modelPath(for: variant)
        let tokenizerFile = tokenizerPath(for: variant)

        return FileManager.default.fileExists(atPath: modelFolder.path)
            && FileManager.default.fileExists(atPath: tokenizerFile.path)
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

    /// Models that have been loaded into memory during this session.
    func loadedModels() -> [String] {
        Array(preloadedModels)
    }

    /// The model currently loaded in the WhisperKit pipeline.
    func currentModel() -> String? {
        currentModelName
    }

    // MARK: - Private

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

        if isModelDownloaded(variant) {
            return
        }

        let tempFolder = try await WhisperKit.download(
            variant: variant,
            downloadBase: nil,
            useBackgroundSession: false,
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
        preloadedModels.insert(modelName)

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
