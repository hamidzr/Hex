import Foundation

enum CLIError: Error, LocalizedError {
    case microphonePermissionDenied
    case invalidInputDevice
    case failedToSetInputDevice
    case transcriptionFailed
    case daemonNotRunning
    case daemonError(String)

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
        case .daemonNotRunning:
            return "Daemon is not running. Start it with: hex-cli daemon"
        case .daemonError(let msg):
            return "Daemon error: \(msg)"
        }
    }
}
