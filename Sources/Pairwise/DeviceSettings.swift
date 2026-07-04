import Foundation
import CoreAudio
import AVFoundation

/// User-chosen capture devices and screen share quality, persisted across
/// launches. nil / 0 means "let the app decide" (system default mic,
/// automatic camera, default share resolution).
enum DeviceSettings {
    private static let micKey = "pairwise.micUID"
    private static let cameraKey = "pairwise.cameraUID"
    private static let shareCapKey = "pairwise.shareMaxDimension"

    static var micUID: String? {
        get { UserDefaults.standard.string(forKey: micKey) }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: micKey) }
            else { UserDefaults.standard.removeObject(forKey: micKey) }
        }
    }

    static var cameraUID: String? {
        get { UserDefaults.standard.string(forKey: cameraKey) }
        set {
            if let newValue { UserDefaults.standard.set(newValue, forKey: cameraKey) }
            else { UserDefaults.standard.removeObject(forKey: cameraKey) }
        }
    }

    /// Long-side pixel cap for the outgoing screen share stream; 0 = native.
    static var screenShareMaxDimension: Int {
        get { UserDefaults.standard.object(forKey: shareCapKey) as? Int ?? 2560 }
        set { UserDefaults.standard.set(newValue, forKey: shareCapKey) }
    }
}

struct AudioInputDevice {
    let id: AudioDeviceID
    let uid: String
    let name: String
}

enum AudioInputDevices {
    /// Every device with input streams, via the HAL. AVCaptureDevice misses
    /// some audio hardware (aggregate outputs of interfaces), and going
    /// straight to CoreAudio also gives us the AudioDeviceID the engine needs.
    static func all() -> [AudioInputDevice] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            var streamsAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreams,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain)
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &streamsAddr, 0, nil, &streamsSize) == noErr,
                  streamsSize > 0 else { return nil }
            guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(id, kAudioObjectPropertyName),
                  // The HAL's internal default-device aggregate is not a real choice.
                  !uid.hasPrefix("CADefaultDeviceAggregate") else { return nil }
            return AudioInputDevice(id: id, uid: uid, name: name)
        }
    }

    private static func stringProperty(_ id: AudioObjectID,
                                       _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let err = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard err == noErr, let value else { return nil }
        return value as String
    }
}
