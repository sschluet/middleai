import AudioToolbox
import CoreAudio
import Foundation

struct AudioInputDevice: Identifiable, Hashable, Sendable {
  let deviceID: AudioDeviceID
  let uid: String
  let name: String
  let isSystemDefault: Bool

  var id: String { uid }
}

struct AudioOutputDevice: Identifiable, Hashable, Sendable {
  let deviceID: AudioDeviceID
  let uid: String
  let name: String
  let isSystemDefault: Bool
  var id: String { uid }
}

enum AudioInputDeviceCatalog {
  static let systemDefaultUID = "system_default"

  static func availableDevices() -> [AudioInputDevice] {
    let defaultID = defaultInputDeviceID()
    return allDeviceIDs()
      .filter(hasInputStreams)
      .compactMap { deviceID in
        guard let uid = stringProperty(kAudioDevicePropertyDeviceUID, for: deviceID),
          let name = stringProperty(kAudioObjectPropertyName, for: deviceID)
        else { return nil }
        return AudioInputDevice(
          deviceID: deviceID, uid: uid, name: name, isSystemDefault: deviceID == defaultID)
      }
      .sorted {
        if $0.isSystemDefault != $1.isSystemDefault { return $0.isSystemDefault }
        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
  }

  static func selectedDevice(for configuredUID: String) -> AudioInputDevice? {
    let devices = availableDevices()
    if configuredUID == systemDefaultUID {
      return devices.first(where: \AudioInputDevice.isSystemDefault)
    }
    return devices.first { $0.uid == configuredUID }
  }

  static func apply(_ device: AudioInputDevice, to audioUnit: AudioUnit) throws {
    var deviceID = device.deviceID
    let status = AudioUnitSetProperty(
      audioUnit,
      kAudioOutputUnitProperty_CurrentDevice,
      kAudioUnitScope_Global,
      0,
      &deviceID,
      UInt32(MemoryLayout<AudioDeviceID>.size))
    guard status == noErr else {
      throw AudioInputDeviceError.couldNotSelect(device.name, status)
    }
  }

  private static func defaultInputDeviceID() -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var deviceID = kAudioObjectUnknown
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr
    else { return kAudioObjectUnknown }
    return deviceID
  }

  private static func allDeviceIDs() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard
      AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr,
      size > 0
    else { return [] }
    var devices = [AudioDeviceID](
      repeating: kAudioObjectUnknown,
      count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr
    else { return [] }
    return devices
  }

  private static func hasInputStreams(_ deviceID: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: kAudioDevicePropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr && size > 0
  }

  private static func stringProperty(
    _ selector: AudioObjectPropertySelector, for deviceID: AudioDeviceID
  ) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
      let value
    else { return nil }
    return value.takeUnretainedValue() as String
  }
}

enum AudioOutputDeviceCatalog {
  static let systemDefaultUID = "system_default"

  static func availableDevices() -> [AudioOutputDevice] {
    let defaultID = defaultOutputDeviceID()
    return allDeviceIDs()
      .filter(hasOutputStreams)
      .compactMap { deviceID in
        guard let uid = stringProperty(kAudioDevicePropertyDeviceUID, for: deviceID),
          let name = stringProperty(kAudioObjectPropertyName, for: deviceID)
        else { return nil }
        return AudioOutputDevice(
          deviceID: deviceID, uid: uid, name: name, isSystemDefault: deviceID == defaultID)
      }
      .sorted {
        if $0.isSystemDefault != $1.isSystemDefault { return $0.isSystemDefault }
        return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
      }
  }

  private static func defaultOutputDeviceID() -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultOutputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var deviceID = kAudioObjectUnknown
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr
    else { return kAudioObjectUnknown }
    return deviceID
  }

  private static func allDeviceIDs() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard
      AudioObjectGetPropertyDataSize(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr, size > 0
    else { return [] }
    var devices = [AudioDeviceID](
      repeating: kAudioObjectUnknown,
      count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard
      AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devices) == noErr
    else { return [] }
    return devices
  }

  private static func hasOutputStreams(_ deviceID: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeOutput,
      mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    return AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr && size > 0
  }

  private static func stringProperty(
    _ selector: AudioObjectPropertySelector, for deviceID: AudioDeviceID
  ) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr,
      let value
    else { return nil }
    return value.takeUnretainedValue() as String
  }
}

enum AudioInputDeviceError: LocalizedError {
  case unavailable
  case couldNotSelect(String, OSStatus)

  var errorDescription: String? {
    switch self {
    case .unavailable:
      return
        "Das ausgewählte Mikrofon ist nicht verfügbar. Bitte in den Spracheingabe-Einstellungen ein anderes Gerät wählen."
    case .couldNotSelect(let name, let status):
      return "Das Mikrofon „\(name)“ konnte nicht aktiviert werden (Core Audio \(status))."
    }
  }
}
