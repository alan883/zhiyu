import CoreAudio
import Foundation
import IOKit

struct InputDevice: Equatable {
    let id: AudioDeviceID
    let name: String          // kAudioObjectPropertyName
    let transport: String     // "内置" | "耳机" | "蓝牙" | "USB" | "有线" | "虚拟" | "未知"

    var isBuiltIn: Bool { transport == "内置" }

    var symbol: String {
        switch transport {
        case "内置": return "laptopcomputer"
        case "耳机": return "headphones"
        case "蓝牙": return name.contains("AirPods") ? "airpods" : "headphones"
        case "USB": return "cable.connector"
        case "有线": return "headphones"
        case "虚拟": return "waveform"
        default: return "mic"
        }
    }
}

enum DeviceInfo {
    private static var listener: AudioObjectPropertyListenerBlock?
    private static var sourceListener: AudioObjectPropertyListenerBlock?
    private static var sourceDevice: AudioDeviceID = kAudioObjectUnknown
    private static var handlers: [(InputDevice?) -> Void] = []

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func sourceAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource,
                                   mScope: kAudioObjectPropertyScopeInput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultInputID() -> AudioDeviceID {
        var addr = address(kAudioHardwarePropertyDefaultInputDevice)
        var id: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &addr, 0, nil, &size, &id)
        return status == noErr ? id : kAudioObjectUnknown
    }

    /// Input device description for `id`, or nil for kAudioObjectUnknown.
    static func info(_ id: AudioDeviceID) -> InputDevice? {
        guard id != kAudioObjectUnknown else { return nil }
        let name = deviceName(id)
        return InputDevice(id: id, name: name, transport: inputTransport(id, name: name))
    }

    /// System default input device, or nil if none.
    static func currentInput() -> InputDevice? {
        info(defaultInputID())
    }

    /// First device with BuiltIn transport that has input streams (the internal mic), or nil.
    static func builtInMicID() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == noErr else { return nil }
        var ids = [AudioDeviceID](repeating: kAudioObjectUnknown,
                                  count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(system, &addr, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { transportName($0) == "内置" && hasInputStreams($0) }
    }

    /// True when the device exposes at least one input stream.
    private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                              mScope: kAudioObjectPropertyScopeInput,
                                              mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr && size > 0
    }

    /// True when the MacBook lid is closed (IOPMrootDomain AppleClamshellState).
    static func isLidClosed() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let closed = IORegistryEntryCreateCFProperty(service, "AppleClamshellState" as CFString,
                                                     kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
        return closed ?? false
    }

    /// Persistent UID string of the device, or nil on error.
    static func uid(_ id: AudioDeviceID) -> String? {
        var addr = address(kAudioDevicePropertyDeviceUID)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &uid) == noErr else { return nil }
        return uid as String
    }

    /// Device to record from. With preferBuiltIn, a Bluetooth default input is replaced by the
    /// built-in mic (the headset then stays in music mode and starts ~0.5 s faster), unless the
    /// lid is closed (built-in mic is off then) or no built-in mic exists.
    static func recordingInput(preferBuiltIn: Bool) -> AudioDeviceID {
        let def = defaultInputID()
        guard preferBuiltIn, def != kAudioObjectUnknown, transportName(def) == "蓝牙",
              !isLidClosed(), let b = builtInMicID() else { return def }
        return b
    }

    /// Calls `onChange` on main now and whenever the default input device
    /// or its data source (e.g. headset plugged into the same jack) changes.
    /// The system listeners live for the app lifetime.
    static func observe(_ onChange: @escaping (InputDevice?) -> Void) {
        handlers.append(onChange)
        if listener == nil {
            var addr = address(kAudioHardwarePropertyDefaultInputDevice)
            let block: AudioObjectPropertyListenerBlock = { _, _ in
                DeviceInfo.attachSourceListener()
                DeviceInfo.notifyAll()
            }
            listener = block
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                &addr, DispatchQueue.main, block)
        }
        attachSourceListener()
        onChange(currentInput())
    }

    private static func notifyAll() {
        let device = currentInput()
        handlers.forEach { $0(device) }
    }

    /// Keeps the data-source listener on the current default input device only.
    private static func attachSourceListener() {
        let dev = defaultInputID()
        if dev == sourceDevice { return }
        if sourceDevice != kAudioObjectUnknown, let old = sourceListener {
            var addr = sourceAddress()
            AudioObjectRemovePropertyListenerBlock(sourceDevice, &addr, DispatchQueue.main, old)
        }
        sourceDevice = kAudioObjectUnknown
        guard dev != kAudioObjectUnknown else { return }
        if sourceListener == nil {
            sourceListener = { _, _ in DeviceInfo.notifyAll() }
        }
        var addr = sourceAddress()
        if AudioObjectAddPropertyListenerBlock(dev, &addr, DispatchQueue.main, sourceListener!) == noErr {
            sourceDevice = dev
        }
    }

    private static func deviceName(_ id: AudioDeviceID) -> String {
        var addr = address(kAudioObjectPropertyName)
        var name: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &name)
        return status == noErr ? (name as String) : "未知设备"
    }

    /// BuiltIn transport is split: the 3.5 mm wired headset mic reports data source 'emic'
    /// (internal mic reports 'imic'); fall back to name keywords.
    private static func inputTransport(_ id: AudioDeviceID, name: String) -> String {
        let transport = transportName(id)
        guard transport == "内置" else { return transport }
        var addr = sourceAddress()
        var src: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &src) == noErr, src == 0x656D6963 {
            return "耳机"
        }
        let lower = name.lowercased()
        let keywords = ["外置", "外接", "耳机", "external", "headset", "headphone"]
        return keywords.contains { lower.contains($0) } ? "耳机" : transport
    }

    private static func transportName(_ id: AudioDeviceID) -> String {
        var addr = address(kAudioDevicePropertyTransportType)
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &type) == noErr else { return "未知" }
        switch type {
        case kAudioDeviceTransportTypeBuiltIn:
            return "内置"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "蓝牙"
        case kAudioDeviceTransportTypeUSB:
            return "USB"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate:
            return "虚拟"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort,
             kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypePCI,
             kAudioDeviceTransportTypeFireWire:
            return "有线"
        default:
            return "未知"
        }
    }
}
