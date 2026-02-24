import Foundation

// MARK: - Socket path

enum DaemonDefaults {
    static var socketPath: String {
        let user = ProcessInfo.processInfo.userName
        return "/tmp/\(user)/hex-daemon.sock"
    }

    static let defaultPreload = [
        "openai_whisper-tiny.en",
        "distil-whisper_distil-large-v3_turbo",
    ]
}

// MARK: - Request

struct DaemonRequest: Codable, Sendable {
    let action: Action
    let audio: String?
    let model: String?
    let language: String?

    enum Action: String, Codable, Sendable {
        case transcribe
        case status
        case preload
    }

    static func transcribe(audio: String, model: String, language: String?) -> DaemonRequest {
        DaemonRequest(action: .transcribe, audio: audio, model: model, language: language)
    }

    static func status() -> DaemonRequest {
        DaemonRequest(action: .status, audio: nil, model: nil, language: nil)
    }

    static func preload(model: String) -> DaemonRequest {
        DaemonRequest(action: .preload, audio: nil, model: model, language: nil)
    }
}

// MARK: - Response

struct DaemonResponse: Codable, Sendable {
    let ok: Bool
    let text: String?
    let seconds: Double?
    let error: String?
    let models: [String]?
    let loaded: String?

    static func success(text: String, seconds: Double) -> DaemonResponse {
        DaemonResponse(ok: true, text: text, seconds: seconds, error: nil, models: nil, loaded: nil)
    }

    static func error(_ message: String) -> DaemonResponse {
        DaemonResponse(ok: false, text: nil, seconds: nil, error: message, models: nil, loaded: nil)
    }

    static func status(models: [String], loaded: String?) -> DaemonResponse {
        DaemonResponse(
            ok: true, text: nil, seconds: nil, error: nil, models: models, loaded: loaded)
    }
}

// MARK: - Wire format helpers

enum DaemonWire {
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    private static let decoder = JSONDecoder()

    /// Encode a request to a newline-terminated Data blob.
    static func encode(_ request: DaemonRequest) throws -> Data {
        var data = try encoder.encode(request)
        data.append(contentsOf: [0x0A])  // newline
        return data
    }

    /// Encode a response to a newline-terminated Data blob.
    static func encode(_ response: DaemonResponse) throws -> Data {
        var data = try encoder.encode(response)
        data.append(contentsOf: [0x0A])  // newline
        return data
    }

    /// Decode a request from Data (newline is optional, stripped if present).
    static func decodeRequest(from data: Data) throws -> DaemonRequest {
        let trimmed = data.trimmingNewlines()
        return try decoder.decode(DaemonRequest.self, from: trimmed)
    }

    /// Decode a response from Data (newline is optional, stripped if present).
    static func decodeResponse(from data: Data) throws -> DaemonResponse {
        let trimmed = data.trimmingNewlines()
        return try decoder.decode(DaemonResponse.self, from: trimmed)
    }
}

private extension Data {
    func trimmingNewlines() -> Data {
        var d = self
        while d.last == 0x0A || d.last == 0x0D {
            d = d.dropLast()
        }
        return d
    }
}
