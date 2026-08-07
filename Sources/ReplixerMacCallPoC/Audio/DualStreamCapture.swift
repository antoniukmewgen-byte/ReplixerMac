import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Step 1.3 smoke test — combines the Phase 1.1 process tap (Telegram output)
/// and the physical microphone into a single aggregate CoreAudio device with
/// one IOProc, so both streams share the same clock domain and arrive
/// time-aligned in every callback. Writes each stream to its own .wav file
/// (mirroring the Windows _loopbackTempPath/_micTempPath split) so sync can
/// be verified independently before mixing (Phase 1.4).
///
/// Risk: unlike MicrophoneSmokeTest (Phase 1.2), which uses AVAudioRecorder
/// and was echo-free, this reads the physical mic via a raw CoreAudio
/// sub-device IOProc — the same low-level path that previously produced an
/// echo/crackle artifact before the AVAudioRecorder rewrite. Listen to the
/// mic-side .wav specifically for that artifact when verifying this step.
enum DualStreamCapture {
    enum StepError: Error {
        case defaultInputDeviceUnavailable
        case micStreamFormatUnavailable
        case tapFormatUnavailable
        case aggregateDeviceCreationFailed(OSStatus)
        case outputFileCreationFailed(Error)
        case ioProcCreationFailed(OSStatus)
        case deviceStartFailed(OSStatus)
    }

    static func run(processObjectID: AudioObjectID, duration: TimeInterval = 15) {
        print("[DualStreamCapture] creating tap for process object \(processObjectID)...")

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var tapID = AudioObjectID.unknown
        let createStatus = AudioHardwareCreateProcessTap(tapDescription, &tapID)
        guard createStatus == noErr else {
            print("[DualStreamCapture] ❌ AudioHardwareCreateProcessTap failed, OSStatus=\(createStatus)")
            return
        }
        print("[DualStreamCapture] ✅ tap created, id=\(tapID)")

        defer {
            let destroyStatus = AudioHardwareDestroyProcessTap(tapID)
            print("[DualStreamCapture] tap destroyed, OSStatus=\(destroyStatus)")
        }

        do {
            try runAggregateIOProcAndWrite(tapID: tapID, tapUID: tapDescription.uuid.uuidString, duration: duration)
        } catch {
            print("[DualStreamCapture] ❌ \(error)")
        }
    }

    private static func runAggregateIOProcAndWrite(tapID: AudioObjectID, tapUID: String, duration: TimeInterval) throws {
        guard var tapStreamFormat: AudioStreamBasicDescription = CAObject.read(tapID, .tapFormat) else {
            throw StepError.tapFormatUnavailable
        }
        guard let tapFormat = AVAudioFormat(streamDescription: &tapStreamFormat) else {
            throw StepError.tapFormatUnavailable
        }
        print("[DualStreamCapture] tap format: \(tapFormat)")

        guard let micDeviceID: AudioObjectID = CAObject.read(AudioObjectID(kAudioObjectSystemObject), .defaultInputDevice),
              let micDeviceUID = CAObject.readString(micDeviceID, .deviceUID) else {
            throw StepError.defaultInputDeviceUnavailable
        }
        print("[DualStreamCapture] default input device UID: \(micDeviceUID)")

        guard var micStreamFormat: AudioStreamBasicDescription = CAObject.readInput(micDeviceID, .streamFormat) else {
            throw StepError.micStreamFormatUnavailable
        }
        guard let micFormat = AVAudioFormat(streamDescription: &micStreamFormat) else {
            throw StepError.micStreamFormatUnavailable
        }
        print("[DualStreamCapture] mic format: \(micFormat)")

        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ReplixerMac-DualStreamCapture",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: micDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: micDeviceUID]
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
        print("[DualStreamCapture] ✅ aggregate device created, id=\(aggregateDeviceID)")

        defer {
            let destroyStatus = AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            print("[DualStreamCapture] aggregate device destroyed, OSStatus=\(destroyStatus)")
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let micURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplixerMac-DualStream-Mic-\(timestamp).wav")
        let tapURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplixerMac-DualStream-Tap-\(timestamp).wav")

        let micFile: AVAudioFile
        let tapFile: AVAudioFile
        do {
            micFile = try AVAudioFile(
                forWriting: micURL,
                settings: micFormat.settings,
                commonFormat: micFormat.commonFormat,
                interleaved: micFormat.isInterleaved
            )
            tapFile = try AVAudioFile(
                forWriting: tapURL,
                settings: tapFormat.settings,
                commonFormat: tapFormat.commonFormat,
                interleaved: tapFormat.isInterleaved
            )
        } catch {
            throw StepError.outputFileCreationFailed(error)
        }
        print("[DualStreamCapture] mic -> \(micURL.path)")
        print("[DualStreamCapture] tap -> \(tapURL.path)")

        var callbackCount = 0
        var micFramesWritten: AVAudioFrameCount = 0
        var tapFramesWritten: AVAudioFrameCount = 0
        var ioProcID: AudioDeviceIOProcID?

        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateDeviceID, nil) { _, inInputData, _, _, _ in
            callbackCount += 1
            let bufferList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))

            if callbackCount == 1 {
                print("[DualStreamCapture] first callback: \(bufferList.count) buffer(s) in list")
                for (index, buffer) in bufferList.enumerated() {
                    print("[DualStreamCapture]   buffer[\(index)]: channels=\(buffer.mNumberChannels), bytes=\(buffer.mDataByteSize)")
                }
            }

            // Buffer order follows the aggregate device's declared construction
            // order: sub-devices (kAudioAggregateDeviceSubDeviceListKey) first,
            // then taps (kAudioAggregateDeviceTapListKey). We declared exactly one
            // of each, so index 0 is always mic, index 1 is always tap — this
            // can't be inferred from channel count, since mic and tap formats can
            // be identical (both were 2ch/44100Hz Float32 in the failed test run).
            guard bufferList.count >= 2 else {
                if callbackCount == 1 {
                    print("[DualStreamCapture]   ⚠️ expected 2 buffers (mic, tap), got \(bufferList.count)")
                }
                return
            }

            if writeSingleBuffer(bufferList[0], format: micFormat, to: micFile) {
                micFramesWritten += bufferList[0].mDataByteSize / micFormat.streamDescription.pointee.mBytesPerFrame
            }
            if writeSingleBuffer(bufferList[1], format: tapFormat, to: tapFile) {
                tapFramesWritten += bufferList[1].mDataByteSize / tapFormat.streamDescription.pointee.mBytesPerFrame
            }
        }
        guard ioStatus == noErr, let ioProcID else { throw StepError.ioProcCreationFailed(ioStatus) }

        defer {
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }

        let startStatus = AudioDeviceStart(aggregateDeviceID, ioProcID)
        guard startStatus == noErr else { throw StepError.deviceStartFailed(startStatus) }
        print("[DualStreamCapture] ✅ device started, recording for \(duration)s (говоріть у дзвінок і в мікрофон, наприклад рахуйте вголос)...")

        Thread.sleep(forTimeInterval: duration)

        AudioDeviceStop(aggregateDeviceID, ioProcID)
        print("[DualStreamCapture] device stopped. IOProc calls: \(callbackCount)")
        print("[DualStreamCapture] mic frames written: \(micFramesWritten), tap frames written: \(tapFramesWritten)")
        print("[DualStreamCapture] ✅ done.")
        print("[DualStreamCapture]   mic: \(micURL.path)")
        print("[DualStreamCapture]   tap: \(tapURL.path)")
    }

    /// Wraps a single AudioBuffer from a multi-buffer list into its own
    /// one-buffer AudioBufferList so it can be handed to
    /// AVAudioPCMBuffer(bufferListNoCopy:), then writes it to `file`.
    private static func writeSingleBuffer(_ buffer: AudioBuffer, format: AVAudioFormat, to file: AVAudioFile) -> Bool {
        var singleBufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)
        return withUnsafeMutablePointer(to: &singleBufferList) { ptr -> Bool in
            guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: ptr) else { return false }
            do {
                try file.write(from: pcmBuffer)
                return true
            } catch {
                print("[DualStreamCapture] ⚠️ write failed: \(error)")
                return false
            }
        }
    }
}
