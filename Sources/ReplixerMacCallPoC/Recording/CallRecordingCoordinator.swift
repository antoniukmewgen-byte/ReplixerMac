import CoreAudio
import Foundation

/// Bridges TelegramCallMonitor's start/end events to AudioMixerEncoder's
/// capture pipeline: resolves the Telegram process object fresh at call
/// start (its AudioObjectID isn't guaranteed stable across separate calls),
/// builds a Windows-parity output path via FileNaming, and starts/stops
/// recording.
///
/// An actor, not a class with manual flags — Swift serializes calls to an
/// actor's methods automatically, so a rapid call-start/call-end flicker
/// from TelegramCallMonitor can't race into a double-start or double-stop
/// (the exact hazard the plan calls out for Phase 1.6; building on an actor
/// now avoids having to retrofit one later).
actor CallRecordingCoordinator {
    private var isRecording = false

    func callStarted(processName: String) {
        guard !isRecording else {
            print("[CallRecordingCoordinator] ⚠️ дзвінок вже записується, ігнорую повторний onCallStarted.")
            return
        }

        guard let processObjectID = ProcessTapSmokeTest.findTelegramProcessObjectID() else {
            print("[CallRecordingCoordinator] ❌ не знайшов Telegram у CoreAudio-процесах на старті дзвінка.")
            return
        }

        do {
            try FileNaming.ensureRecordingsDirectoryExists()
        } catch {
            print("[CallRecordingCoordinator] ❌ не вдалося створити теку записів: \(error)")
            return
        }

        let outputURL = FileNaming.recordingURL(platform: "Telegram")
        guard AudioMixerEncoder.start(processObjectID: processObjectID, outputURL: outputURL) else {
            print("[CallRecordingCoordinator] ❌ не вдалося почати запис.")
            return
        }

        isRecording = true
        print("[CallRecordingCoordinator] 🔴 запис почався -> \(outputURL.path)")
    }

    func callEnded(processName: String) {
        guard isRecording else {
            print("[CallRecordingCoordinator] ⚠️ onCallEnded без активного запису — ігнорую.")
            return
        }

        AudioMixerEncoder.stop()
        isRecording = false
        print("[CallRecordingCoordinator] ⏹️ запис зупинено.")
    }

    /// Called from main.swift's SIGINT/SIGTERM handlers so a Ctrl+C or
    /// `kill <pid>` during an active call still finalizes the recording
    /// (stop() renames the .inprogress file to its real name) instead of
    /// leaving a truncated file behind. Can't help against `kill -9`
    /// (SIGKILL isn't catchable) — FileNaming.cleanupStalePartialFiles()
    /// covers that case on the next startup instead.
    func shutdown() {
        guard isRecording else { return }
        print("[CallRecordingCoordinator] 🛑 завершення роботи під час активного запису — коректно зупиняю...")
        AudioMixerEncoder.stop()
        isRecording = false
    }
}
