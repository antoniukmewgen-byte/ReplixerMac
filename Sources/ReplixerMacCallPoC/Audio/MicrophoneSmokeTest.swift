import AVFoundation
import Foundation

/// Step A smoke test for Phase 1.2 — records raw microphone input via
/// AVAudioRecorder into a .wav file, in isolation from any process-tap
/// code. Purpose: confirm the TCC microphone-permission prompt actually
/// appears for a bare CLI/Xcode-run binary (Risk #2 from the plan) and
/// that basic mic capture works, before combining it with process-tap
/// capture in Phase 1.3.
///
/// Uses AVAudioRecorder (Apple's dedicated mic-to-file recording class)
/// instead of a hand-built AVAudioEngine tap graph — manual buffer/channel
/// handling via installTap produced a persistent echo/crackle artifact
/// across several different downmix strategies, all sharing the same
/// underlying tap-based capture path.
enum MicrophoneSmokeTest {
    private static var recorder: AVAudioRecorder?

    static func run(duration: TimeInterval = 10) {
        requestPermission { granted in
            guard granted else {
                print("[MicrophoneSmokeTest] ❌ дозвіл на мікрофон не надано.")
                exit(0)
            }
            recordAndWrite(duration: duration)
        }
    }

    private static func requestPermission(completion: @escaping (Bool) -> Void) {
        print("[MicrophoneSmokeTest] запитую дозвіл на мікрофон...")
        AVAudioApplication.requestRecordPermission { granted in
            print("[MicrophoneSmokeTest] дозвіл: \(granted ? "✅ надано" : "❌ відхилено")")
            completion(granted)
        }
    }

    private static func recordAndWrite(duration: TimeInterval) {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReplixerMac-MicSmokeTest-\(Int(Date().timeIntervalSince1970)).wav")

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 44100,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]

        do {
            let recorder = try AVAudioRecorder(url: outputURL, settings: settings)
            self.recorder = recorder
            guard recorder.record() else {
                print("[MicrophoneSmokeTest] ❌ recorder.record() повернув false")
                exit(0)
            }
        } catch {
            print("[MicrophoneSmokeTest] ❌ не вдалося створити recorder: \(error)")
            exit(0)
        }

        print("[MicrophoneSmokeTest] writing to \(outputURL.path)")
        print("[MicrophoneSmokeTest] ✅ запис триває \(duration)с (кажіть щось у мікрофон)...")

        Thread.sleep(forTimeInterval: duration)

        recorder?.stop()

        print("[MicrophoneSmokeTest] зупинено.")
        print("[MicrophoneSmokeTest] ✅ done. Файл: \(outputURL.path)")
        exit(0)
    }
}
