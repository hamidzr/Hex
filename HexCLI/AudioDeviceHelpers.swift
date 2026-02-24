import CoreAudio
import Foundation

struct AudioInputDevice {
    let id: String
    let name: String
}

enum AudioDeviceHelpers {
    static func getAllAudioDevices() -> [AudioDeviceID] {
        var propertySize: UInt32 = 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject),
                &address, 0, nil, &propertySize
            ) == 0
        else { return [] }

        let deviceCount = Int(propertySize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        guard
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address, 0, nil, &propertySize, &deviceIDs
            ) == 0
        else { return [] }

        return deviceIDs
    }

    static func deviceHasInput(deviceID: AudioDeviceID) -> Bool {
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

    static func getDeviceName(deviceID: AudioDeviceID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceNameCFString,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == 0 else {
            return nil
        }

        let deviceNamePtr = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
        defer { deviceNamePtr.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, deviceNamePtr) == 0
        else {
            return nil
        }

        return deviceNamePtr.pointee as String?
    }
}
