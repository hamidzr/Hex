import AVFoundation
import CoreAudio
import Foundation

actor CLIRecordingClient {
    private var recorder: AVAudioRecorder?
    private let recordingURL = FileManager.default.temporaryDirectory.appendingPathComponent(
        "hex-cli-recording.wav")

    func requestMicrophoneAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func setInputDevice(_ deviceID: String) async throws {
        guard let audioDeviceID = AudioDeviceID(deviceID) else {
            throw CLIError.invalidInputDevice
        }

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
}
