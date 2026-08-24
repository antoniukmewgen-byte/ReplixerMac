import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

/// Phase 1.4 mixing/encoding engine — combines the process tap (Telegram
/// output) and physical microphone into a single aggregated CoreAudio device
/// with one IOProc, sums the two streams sample-by-sample in real time, and
/// writes the result straight to a single AAC/.m4a file via AVAudioFile.
/// AVAudioConverter is only invoked when the mic's format actually differs
/// from the tap's (sample rate and/or channel count).
///
/// Exposes a `start(processObjectID:outputURL:)` / `stop()` lifecycle (state
/// held in static vars, since only one recording can run at a time) so
/// Phase 1.5's CallRecordingCoordinator can drive it from real call
/// start/end events instead of a fixed duration. `run(processObjectID:)` is
/// kept as a smoke-test convenience wrapper around that same lifecycle.
public enum AudioMixerEncoder {
    enum StepError: Error {
        case tapCreationFailed(OSStatus)
        case defaultInputDeviceUnavailable
        case micStreamFormatUnavailable
        case tapFormatUnavailable
        case mixFormatUnavailable
        case converterCreationFailed
        case aggregateDeviceCreationFailed(OSStatus)
        case outputFileCreationFailed(Error)
        case ioProcCreationFailed(OSStatus)
        case deviceStartFailed(OSStatus)
    }

    private static var isActive = false
    private static var tapID: AudioObjectID?
    private static var aggregateDeviceID: AudioObjectID?
    private static var ioProcID: AudioDeviceIOProcID?
    private static var finalOutputURL: URL?
    private static var partialOutputURL: URL?

    /// Set by `start()` whenever `performStart` throws, so a caller who only
    /// sees the `Bool` return value can still find out *which* `StepError`
    /// case actually fired (was previously only visible in a `print()` that
    /// never left the local console — see the 2026-08-24 "AudioMixerEncoder
    /// .start повернув false" WhatsApp error report, which arrived with zero
    /// diagnostic detail because `CallRecordingCoordinator` had nothing to
    /// pass as `ErrorReporter.report`'s `error:` argument). Cleared on the
    /// next successful `start()` so a stale error can't be misattributed to
    /// a later, unrelated failure.
    public private(set) static var lastStartError: Error?

    /// Starts capture+mix+encode. `processObjectID` targets one specific
    /// running process's audio (the auto-detected-call path, via
    /// `CallRecordingCoordinator.callStarted`); pass `nil` for a system-wide
    /// tap that mixes down *all* process output instead of one process —
    /// Windows parity: `HomeViewModel.ManualStartRecording` doesn't resolve
    /// "which app is calling" either, since `WasapiLoopbackCapture` already
    /// captures whatever's making sound system-wide. See
    /// `CallRecordingCoordinator.manualStart()`'s doc comment for why manual
    /// recording specifically needs this branch.
    ///
    /// Writes to a `.inprogress` sibling of `outputURL` (see
    /// FileNaming.partialURL) and only renames it to `outputURL` on a clean
    /// `stop()` — so a crash or `kill -9` mid-recording leaves an obviously-
    /// partial file behind instead of something that looks like a finished
    /// recording. No-op (returns false) if a recording is already active —
    /// callers are expected to call `stop()` first. On any failure, whatever
    /// CoreAudio state was partially created is torn down before returning,
    /// so a failed start never leaks a tap/aggregate device.
    @discardableResult
    static func start(processObjectID: AudioObjectID?, outputURL: URL) -> Bool {
        guard !isActive else {
            print("[AudioMixerEncoder] ⚠️ start() викликано, поки вже активний запис — ігнорую.")
            return false
        }
        let partialURL = FileNaming.partialURL(for: outputURL)
        do {
            try performStart(processObjectID: processObjectID, outputURL: partialURL)
            isActive = true
            finalOutputURL = outputURL
            partialOutputURL = partialURL
            lastStartError = nil
            return true
        } catch {
            print("[AudioMixerEncoder] ❌ \(error)")
            lastStartError = error
            return false
        }
    }

    /// Tears down CoreAudio state and, on a clean stop, renames the
    /// `.inprogress` file to its real final name. If the rename itself fails
    /// (rare — e.g. disk full), the `.inprogress` file is left in place
    /// rather than silently losing the recording; it'll show up for manual
    /// recovery instead of being swept by the next stale-file cleanup pass
    /// only after enough time to notice.
    ///
    /// Returns the final URL on a successful rename, nil otherwise (nothing
    /// was active, or the rename failed) — Phase 2.2's CallRecordingCoordinator
    /// uses this to record the recording as `.saved` vs `.error` in history.
    @discardableResult
    static func stop() -> URL? {
        guard isActive else { return nil }

        if let ioProcID, let aggregateDeviceID {
            AudioDeviceStop(aggregateDeviceID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateDeviceID, ioProcID)
        }
        if let aggregateDeviceID {
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
        }
        if let tapID {
            AudioHardwareDestroyProcessTap(tapID)
        }

        var renamedURL: URL?
        if let partialOutputURL, let finalOutputURL {
            // Re-check for a same-name collision right here, immediately
            // before actually claiming the name — see
            // FileNaming.resolveCollision's doc comment for why the
            // start-time check in FileNaming.recordingURL alone isn't
            // enough (two calls starting in the same {yy.MM.dd}_{HH.mm}
            // minute can both compute the same candidate).
            let resolvedFinalURL = FileNaming.resolveCollision(for: finalOutputURL)
            do {
                try FileManager.default.moveItem(at: partialOutputURL, to: resolvedFinalURL)
                print("[AudioMixerEncoder] ✅ файл готовий: \(resolvedFinalURL.path)")
                renamedURL = resolvedFinalURL
            } catch {
                print("[AudioMixerEncoder] ⚠️ не вдалося перейменувати \(partialOutputURL.lastPathComponent) -> \(resolvedFinalURL.lastPathComponent): \(error)")
            }
        }

        ioProcID = nil
        aggregateDeviceID = nil
        tapID = nil
        finalOutputURL = nil
        partialOutputURL = nil
        isActive = false
        return renamedURL
    }

    /// Step 1.4 smoke-test entry point (`--mix-smoke-test`): start, sleep for
    /// `duration`, stop. Writes to a temp file since it isn't tied to a real
    /// call's lifecycle.
    public static func run(processObjectID: AudioObjectID, duration: TimeInterval = 60) {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplixerMac-Mixed-\(Int(Date().timeIntervalSince1970)).m4a")

        guard start(processObjectID: processObjectID, outputURL: outputURL) else { return }

        print("[AudioMixerEncoder] ✅ device started, recording for \(duration)s (говоріть у дзвінок і в мікрофон, наприклад рахуйте вголос по черзі)...")

        Thread.sleep(forTimeInterval: duration)

        stop()
    }

    private static func performStart(processObjectID: AudioObjectID?, outputURL: URL) throws {
        let tapDescription: CATapDescription
        if let processObjectID {
            print("[AudioMixerEncoder] creating tap for process object \(processObjectID)...")
            tapDescription = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        } else {
            // Manual start with no specific process to target — an empty
            // exclude list means "exclude nothing", i.e. tap every process's
            // output system-wide, same net effect as Windows'
            // WasapiLoopbackCapture. See `start(processObjectID:outputURL:)`'s
            // doc comment.
            print("[AudioMixerEncoder] creating system-wide tap (manual start, no specific process)...")
            tapDescription = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        }
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var newTapID = AudioObjectID.unknown
        let createStatus = AudioHardwareCreateProcessTap(tapDescription, &newTapID)
        guard createStatus == noErr else {
            throw StepError.tapCreationFailed(createStatus)
        }
        print("[AudioMixerEncoder] ✅ tap created, id=\(newTapID)")

        do {
            guard var tapStreamFormat: AudioStreamBasicDescription = CAObject.read(newTapID, .tapFormat),
                  let tapFormat = AVAudioFormat(streamDescription: &tapStreamFormat) else {
                throw StepError.tapFormatUnavailable
            }
            print("[AudioMixerEncoder] tap format: \(tapFormat)")

            guard let micDeviceID: AudioObjectID = CAObject.read(AudioObjectID(kAudioObjectSystemObject), .defaultInputDevice),
                  let micDeviceUID = CAObject.readString(micDeviceID, .deviceUID) else {
                throw StepError.defaultInputDeviceUnavailable
            }
            print("[AudioMixerEncoder] default input device UID: \(micDeviceUID)")

            guard var micStreamFormat: AudioStreamBasicDescription = CAObject.readInput(micDeviceID, .streamFormat),
                  let micFormat = AVAudioFormat(streamDescription: &micStreamFormat) else {
                throw StepError.micStreamFormatUnavailable
            }
            print("[AudioMixerEncoder] mic format: \(micFormat)")

            // Mix in the tap's format (matches system output — the common case
            // on a call). If the mic's format differs, convert mic buffers into
            // the tap's format before summation; AVAudioConverter handles both
            // sample-rate resampling and channel-count up/down-mixing.
            guard let mixFormat = AVAudioFormat(
                commonFormat: tapFormat.commonFormat,
                sampleRate: tapFormat.sampleRate,
                channels: tapFormat.channelCount,
                interleaved: tapFormat.isInterleaved
            ) else {
                throw StepError.mixFormatUnavailable
            }
            print("[AudioMixerEncoder] mix format: \(mixFormat)")

            let needsMicConversion = micFormat.sampleRate != mixFormat.sampleRate || micFormat.channelCount != mixFormat.channelCount
            let micConverter: AVAudioConverter?
            if needsMicConversion {
                guard let converter = AVAudioConverter(from: micFormat, to: mixFormat) else {
                    throw StepError.converterCreationFailed
                }
                micConverter = converter
                print("[AudioMixerEncoder] mic format differs from mix format — will resample/convert per callback")
            } else {
                micConverter = nil
            }

            let aggregateDescription: [String: Any] = [
                kAudioAggregateDeviceNameKey: "ReplixerMac-CallRecording",
                kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: micDeviceUID,
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [
                    [kAudioSubDeviceUIDKey: micDeviceUID]
                ],
                kAudioAggregateDeviceTapListKey: [
                    [
                        kAudioSubTapUIDKey: tapDescription.uuid.uuidString,
                        kAudioSubTapDriftCompensationKey: true
                    ]
                ]
            ]

            var newAggregateDeviceID = AudioObjectID.unknown
            let aggregateStatus = AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &newAggregateDeviceID)
            guard aggregateStatus == noErr else {
                throw StepError.aggregateDeviceCreationFailed(aggregateStatus)
            }
            print("[AudioMixerEncoder] ✅ aggregate device created, id=\(newAggregateDeviceID)")

            do {
                let aacSettings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                    AVSampleRateKey: mixFormat.sampleRate,
                    AVNumberOfChannelsKey: Int(mixFormat.channelCount),
                    AVEncoderBitRateKey: 128_000
                ]

                let outputFile: AVAudioFile
                do {
                    outputFile = try AVAudioFile(
                        forWriting: outputURL,
                        settings: aacSettings,
                        commonFormat: mixFormat.commonFormat,
                        interleaved: mixFormat.isInterleaved
                    )
                } catch {
                    throw StepError.outputFileCreationFailed(error)
                }
                print("[AudioMixerEncoder] output -> \(outputURL.path)")

                var newIOProcID: AudioDeviceIOProcID?
                let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&newIOProcID, newAggregateDeviceID, nil) { _, inInputData, _, _, _ in
                    let bufferList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))

                    // Buffer order follows the aggregate's declared construction
                    // order — sub-devices first, then taps — confirmed in
                    // Phase 1.3: index 0 = mic, index 1 = tap.
                    guard bufferList.count >= 2 else { return }

                    guard let micPCMBuffer = pcmBuffer(from: bufferList[0], format: micFormat),
                          let tapPCMBuffer = pcmBuffer(from: bufferList[1], format: tapFormat) else {
                        return
                    }

                    let resampledMicBuffer: AVAudioPCMBuffer
                    if let micConverter {
                        guard let converted = convert(micPCMBuffer, using: micConverter, to: mixFormat) else {
                            return
                        }
                        resampledMicBuffer = converted
                    } else {
                        resampledMicBuffer = micPCMBuffer
                    }

                    guard let mixedBuffer = sum(resampledMicBuffer, tapPCMBuffer, format: mixFormat) else {
                        return
                    }

                    do {
                        try outputFile.write(from: mixedBuffer)
                    } catch {
                        print("[AudioMixerEncoder] ⚠️ write failed: \(error)")
                    }
                }
                guard ioStatus == noErr, let newIOProcID else {
                    throw StepError.ioProcCreationFailed(ioStatus)
                }

                let startStatus = AudioDeviceStart(newAggregateDeviceID, newIOProcID)
                guard startStatus == noErr else {
                    AudioDeviceDestroyIOProcID(newAggregateDeviceID, newIOProcID)
                    throw StepError.deviceStartFailed(startStatus)
                }

                // Everything succeeded — commit state so stop() can tear it
                // down later. Until this point, any thrown error unwinds via
                // the do/catch blocks below, which destroy exactly what was
                // already created.
                tapID = newTapID
                aggregateDeviceID = newAggregateDeviceID
                ioProcID = newIOProcID
                print("[AudioMixerEncoder] ✅ device started")
            } catch {
                AudioHardwareDestroyAggregateDevice(newAggregateDeviceID)
                throw error
            }
        } catch {
            AudioHardwareDestroyProcessTap(newTapID)
            throw error
        }
    }

    /// Wraps a single AudioBuffer into a one-buffer AudioBufferList and hands
    /// it to AVAudioPCMBuffer(bufferListNoCopy:) so it can be converted/summed
    /// before writing.
    private static func pcmBuffer(from buffer: AudioBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        var singleBufferList = AudioBufferList(mNumberBuffers: 1, mBuffers: buffer)
        return withUnsafeMutablePointer(to: &singleBufferList) { ptr in
            AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: ptr)
        }
    }

    private static func convert(_ buffer: AVAudioPCMBuffer, using converter: AVAudioConverter, to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        // Output frame capacity scales with the sample-rate ratio (plus slack)
        // so the converter always has room for the resampled result.
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }

        var error: NSError?
        var suppliedInput = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if suppliedInput {
                outStatus.pointee = .noDataNow
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return buffer
        }
        if let error {
            print("[AudioMixerEncoder] ⚠️ mic conversion failed: \(error)")
            return nil
        }
        return outputBuffer
    }

    /// Sums two same-format float PCM buffers sample-by-sample, clamping to
    /// [-1, 1] so simultaneous speech on both sides doesn't wrap/clip harshly.
    private static func sum(_ a: AVAudioPCMBuffer, _ b: AVAudioPCMBuffer, format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let frameLength = min(a.frameLength, b.frameLength)
        guard frameLength > 0,
              let mixed = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        mixed.frameLength = frameLength

        if format.isInterleaved {
            guard let aData = a.floatChannelData?[0],
                  let bData = b.floatChannelData?[0],
                  let mixedData = mixed.floatChannelData?[0] else { return nil }
            let sampleCount = Int(frameLength) * Int(format.channelCount)
            for i in 0..<sampleCount {
                mixedData[i] = max(-1.0, min(1.0, aData[i] + bData[i]))
            }
        } else {
            for channel in 0..<Int(format.channelCount) {
                guard let aData = a.floatChannelData?[channel],
                      let bData = b.floatChannelData?[channel],
                      let mixedData = mixed.floatChannelData?[channel] else { return nil }
                for i in 0..<Int(frameLength) {
                    mixedData[i] = max(-1.0, min(1.0, aData[i] + bData[i]))
                }
            }
        }
        return mixed
    }
}
