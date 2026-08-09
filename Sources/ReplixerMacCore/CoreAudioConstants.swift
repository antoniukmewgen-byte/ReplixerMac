import CoreAudio

/// FourCC-based selectors for the CoreAudio "process object" API
/// (macOS 14.2+). Defined by hand rather than trusting the named SDK
/// constants (kAudioHardwarePropertyProcessObjectList, etc.) to be present
/// in whatever Swift CoreAudio overlay version is on the build machine —
/// the FourCC codes themselves are stable ABI, the Swift symbol names are not.
enum CAFourCC {
    static func make(_ s: String) -> UInt32 {
        precondition(s.count == 4, "FourCC must be exactly 4 ASCII chars")
        var result: UInt32 = 0
        for byte in s.utf8 { result = (result << 8) | UInt32(byte) }
        return result
    }
}

extension AudioObjectPropertySelector {
    /// kAudioHardwarePropertyProcessObjectList — array of AudioObjectID,
    /// one per process known to the audio HAL. Query on the system object.
    static let processObjectList: AudioObjectPropertySelector = CAFourCC.make("prs#")

    /// Per-process properties (AudioObjectID = process object).
    static let processPID: AudioObjectPropertySelector = CAFourCC.make("ppid")
    static let processBundleID: AudioObjectPropertySelector = CAFourCC.make("pbid")
    static let processIsRunningInput: AudioObjectPropertySelector = CAFourCC.make("piri")
    static let processIsRunningOutput: AudioObjectPropertySelector = CAFourCC.make("piro")
}

extension AudioObjectPropertyAddress {
    static func global(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    static func input(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}

extension AudioObjectPropertySelector {
    /// kAudioTapPropertyFormat ('tfmt') — AudioStreamBasicDescription of a process tap's
    /// captured stream. Confirmed present in CoreAudio/AudioHardware.h on the MacOSX14.2 SDK
    /// (verified directly against the build machine's headers), used via its named constant.
    static let tapFormat = kAudioTapPropertyFormat

    /// kAudioHardwarePropertyDefaultOutputDevice / kAudioDevicePropertyDeviceUID — long-stable
    /// (pre-Sonoma) named constants, safe to use directly.
    static let defaultOutputDevice = kAudioHardwarePropertyDefaultOutputDevice
    static let deviceUID = kAudioDevicePropertyDeviceUID

    /// kAudioHardwarePropertyDefaultInputDevice — physical mic device, needed for Phase 1.3
    /// (combining it into the same aggregate device as the process tap).
    static let defaultInputDevice = kAudioHardwarePropertyDefaultInputDevice

    /// kAudioDevicePropertyStreamFormat — a device's own nominal stream format. Must be read
    /// with the .input scope for an input device, unlike the other selectors above which are
    /// global-scope.
    static let streamFormat = kAudioDevicePropertyStreamFormat
}

extension AudioObjectID {
    static let unknown = AudioObjectID(kAudioObjectUnknown)
}

enum CAObject {
    static func read<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        read(object, address: .global(selector))
    }

    static func readInput<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> T? {
        read(object, address: .input(selector))
    }

    private static func read<T>(_ object: AudioObjectID, address: AudioObjectPropertyAddress) -> T? {
        var address = address
        var size = UInt32(MemoryLayout<T>.size)
        let value = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { value.deallocate() }

        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, value)
        guard status == noErr else { return nil }
        return value.pointee
    }

    static func readString(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress.global(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var cfStr: CFString? = nil

        let status = withUnsafeMutablePointer(to: &cfStr) { ptr in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, ptr)
        }
        guard status == noErr, let cfStr else { return nil }
        return cfStr as String
    }

    static func readArray<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, of: T.Type = T.self) -> [T] {
        var address = AudioObjectPropertyAddress.global(selector)
        var size: UInt32 = 0

        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr, size > 0 else {
            return []
        }

        let count = Int(size) / MemoryLayout<T>.size
        let buffer = UnsafeMutableBufferPointer<T>.allocate(capacity: count)
        defer { buffer.deallocate() }

        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, buffer.baseAddress!) == noErr else {
            return []
        }
        return Array(buffer.prefix(count))
    }
}
