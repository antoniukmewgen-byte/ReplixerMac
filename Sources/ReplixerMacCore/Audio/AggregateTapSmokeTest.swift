import AudioToolbox
import CoreAudio
import Foundation

/// Step C smoke test for Phase 1.1 — builds on the Step B tap by wrapping
/// it in an aggregate device and registering an IOProc. Logs how many
/// callback invocations happen and the size of the first buffer seen. No
/// file writing yet — that's Step D, once we know audio is actually
/// flowing through the callback.
public enum AggregateTapSmokeTest {
    enum StepError: Error {
        case defaultOutputDeviceUIDUnavailable
        case aggregateDeviceCreationFailed(OSStatus)
        case ioProcCreationFailed(OSStatus)
        case deviceStartFailed(OSStatus)
    }

    public static func run(processObjectID: AudioObjectID, duration: TimeInterval = 8) {
        print("[AggregateTapSmokeTest] creating tap for process object \(processObjectID)...")

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var tapID = AudioObjectID.unknown
        let createStatus = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard createStatus == noErr else {
            print("[AggregateTapSmokeTest] ❌ AudioHardwareCreateProcessTap failed, OSStatus=\(createStatus)")
            return
        }
        print("[AggregateTapSmokeTest] ✅ tap created, id=\(tapID)")

        defer {
            let destroyStatus = AudioHardwareDestroyProcessTap(tapID)
            print("[AggregateTapSmokeTest] tap destroyed, OSStatus=\(destroyStatus)")
        }

        do {
            try runAggregateAndIOProc(tapID: tapID, tapUID: tapDescription.uuid.uuidString, duration: duration)
        } catch {
            print("[AggregateTapSmokeTest] ❌ \(error)")
        }
    }

    private static func runAggregateAndIOProc(tapID: AudioObjectID, tapUID: String, duration: TimeInterval) throws {
        guard let outputDeviceUID = defaultOutputDeviceUID() else {
            throw StepError.defaultOutputDeviceUIDUnavailable
        }
        print("[AggregateTapSmokeTest] default output device UID: \(outputDeviceUID)")

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ReplixerMac-Tap-SmokeTest",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapUIDKey: tapUID,
                    kAudioSubTapDriftCompensationKey: true
                ]
            ]
        ]

        var aggregateDeviceID = AudioObjectID.unknown
        let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregateDeviceID)
        guard aggregateStatus == noErr else { throw StepError.aggregateDeviceCreationFailed(aggregateStatus) }
        print("[AggregateTapSmokeTest] ✅ aggregate device created, id=\(aggregateDeviceID)")

        defer {
            let destroyStatus = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            print("[AggregateTapSmokeTest] aggregate device destroyed, OSStatus=\(destroyStatus)")
        }

        var callbackCount = 0
        var ioProcID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, nil) { _, inInputData, _, _, _ in
            callbackCount += 1
            if callbackCount == 1 || callbackCount % 50 == 0 {
                let bufferList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
                let byteSize = bufferList.first?.mDataByteSize ?? 0
                print("[AggregateTapSmokeTest] IOProc call #\(callbackCount), first buffer bytes=\(byteSize)")
            }
        }
        guard ioStatus == noErr, let ioProcID else { throw StepError.ioProcCreationFailed(ioStatus) }

        defer {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }

        let startStatus = AudioDeviceStart(aggregateDeviceID, ioProcID)
        guard startStatus == noErr else { throw StepError.deviceStartFailed(startStatus) }
        print("[AggregateTapSmokeTest] ✅ device started, capturing for \(duration)s (кажіть щось у дзвінок)...")

        Thread.sleep(forTimeInterval: duration)

        AudioDeviceStop(aggregateDeviceID, ioProcID)
        print("[AggregateTapSmokeTest] device stopped. Total IOProc calls: \(callbackCount)")
    }

    private static func defaultOutputDeviceUID() -> String? {
        guard let deviceID: AudioObjectID = CAObject.read(AudioObjectID(kAudioObjectSystemObject), .defaultOutputDevice) else {
            return nil
        }
        return CAObject.readString(deviceID, .deviceUID)
    }
}
