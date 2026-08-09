import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Step D smoke test for Phase 1.1 — extends Step C by writing captured
/// buffers to a real .wav file via AVAudioFile, so the result can be
/// opened in QuickTime/Audacity and checked for actual, audible
/// output-side audio. This is the final verification criterion from the
/// original Phase 1.1 plan.
public enum TapFileWriteSmokeTest {
    enum StepError: Error {
        case tapFormatUnavailable
        case defaultOutputDeviceUIDUnavailable
        case aggregateDeviceCreationFailed(OSStatus)
        case outputFileCreationFailed(Error)
        case ioProcCreationFailed(OSStatus)
        case deviceStartFailed(OSStatus)
    }

    public static func run(processObjectID: AudioObjectID, duration: TimeInterval = 10) {
        print("[TapFileWriteSmokeTest] creating tap for process object \(processObjectID)...")

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var tapID = AudioObjectID.unknown
        let createStatus = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard createStatus == noErr else {
            print("[TapFileWriteSmokeTest] ❌ AudioHardwareCreateProcessTap failed, OSStatus=\(createStatus)")
            return
        }
        print("[TapFileWriteSmokeTest] ✅ tap created, id=\(tapID)")

        defer {
            let destroyStatus = AudioHardwareDestroyProcessTap(tapID)
            print("[TapFileWriteSmokeTest] tap destroyed, OSStatus=\(destroyStatus)")
        }

        do {
            try runAggregateIOProcAndWrite(tapID: tapID, tapUID: tapDescription.uuid.uuidString, duration: duration)
        } catch {
            print("[TapFileWriteSmokeTest] ❌ \(error)")
        }
    }

    private static func runAggregateIOProcAndWrite(tapID: AudioObjectID, tapUID: String, duration: TimeInterval) throws {
        guard var tapFormat: AudioStreamBasicDescription = CAObject.read(tapID, .tapFormat) else {
            throw StepError.tapFormatUnavailable
        }
        guard let avFormat = AVAudioFormat(streamDescription: &tapFormat) else {
            throw StepError.tapFormatUnavailable
        }
        print("[TapFileWriteSmokeTest] tap format: \(avFormat)")

        guard let outputDeviceUID = defaultOutputDeviceUID() else {
            throw StepError.defaultOutputDeviceUIDUnavailable
        }

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ReplixerMac-Tap-FileWriteSmokeTest",
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
        print("[TapFileWriteSmokeTest] ✅ aggregate device created, id=\(aggregateDeviceID)")

        defer {
            let destroyStatus = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            print("[TapFileWriteSmokeTest] aggregate device destroyed, OSStatus=\(destroyStatus)")
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplixerMac-TapSmokeTest-\(Int(Date().timeIntervalSince1970)).wav")

        let outputFile: AVAudioFile
        do {
            outputFile = try AVAudioFile(
                forWriting: outputURL,
                settings: avFormat.settings,
                commonFormat: avFormat.commonFormat,
                interleaved: avFormat.isInterleaved
            )
        } catch {
            throw StepError.outputFileCreationFailed(error)
        }
        print("[TapFileWriteSmokeTest] writing to \(outputURL.path)")

        var callbackCount = 0
        var framesWritten: AVAudioFrameCount = 0
        var ioProcID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, nil) { _, inInputData, _, _, _ in
            callbackCount += 1
            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: avFormat, bufferListNoCopy: inInputData) else { return }
            do {
                try outputFile.write(from: pcmBuffer)
                framesWritten += pcmBuffer.frameLength
            } catch {
                print("[TapFileWriteSmokeTest] ⚠️ write failed: \(error)")
            }
        }
        guard ioStatus == noErr, let ioProcID else { throw StepError.ioProcCreationFailed(ioStatus) }

        defer {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }

        let startStatus = AudioDeviceStart(aggregateDeviceID, ioProcID)
        guard startStatus == noErr else { throw StepError.deviceStartFailed(startStatus) }
        print("[TapFileWriteSmokeTest] ✅ device started, recording for \(duration)s (кажіть щось у дзвінок)...")

        Thread.sleep(forTimeInterval: duration)

        AudioDeviceStop(aggregateDeviceID, ioProcID)
        print("[TapFileWriteSmokeTest] device stopped. IOProc calls: \(callbackCount), frames written: \(framesWritten)")
        print("[TapFileWriteSmokeTest] ✅ done. Файл: \(outputURL.path)")
    }

    private static func defaultOutputDeviceUID() -> String? {
        guard let deviceID: AudioObjectID = CAObject.read(AudioObjectID(kAudioObjectSystemObject), .defaultOutputDevice) else {
            return nil
        }
        return CAObject.readString(deviceID, .deviceUID)
    }
}
