import AppKit
import CoreAudio
import Foundation

/// Polls the CoreAudio HAL process list once a second and reports a call as
/// "active" when the Telegram process has both input (mic) and output
/// (speaker) IO running at the same time — the same heuristic the Windows
/// build uses via WASAPI sessions + the microphone consent-store registry key.
final class TelegramCallMonitor {
    var onCallStarted: ((_ processName: String) -> Void)?
    var onCallEnded: ((_ processName: String) -> Void)?

    private let targetNameSubstring = "Telegram"
    private var isCallActive = false
    private var pollTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.replixer.telegram-call-monitor")

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        pollTimer = timer
    }

    func stop() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    private func poll() {
        let processIDs: [AudioObjectID] = CAObject.readArray(
            AudioObjectID(kAudioObjectSystemObject),
            .processObjectList
        )

        for objectID in processIDs {
            guard let pid: pid_t = CAObject.read(objectID, .processPID) else { continue }
            guard let name = processName(for: pid), name.contains(targetNameSubstring) else { continue }

            let isRunningInput: UInt32 = CAObject.read(objectID, .processIsRunningInput) ?? 0
            let isRunningOutput: UInt32 = CAObject.read(objectID, .processIsRunningOutput) ?? 0
            let micAndSpeakerActive = isRunningInput != 0 && isRunningOutput != 0

            if micAndSpeakerActive && !isCallActive {
                isCallActive = true
                onCallStarted?(name)
            } else if !micAndSpeakerActive && isCallActive {
                isCallActive = false
                onCallEnded?(name)
            }
            return
        }

        if isCallActive {
            isCallActive = false
            onCallEnded?(targetNameSubstring)
        }
    }

    /// Prefer the running application's localized/bundle name over the raw
    /// CoreAudio bundle-ID property, since Telegram Desktop (Qt) and the
    /// native macOS client register under different bundle identifiers.
    private func processName(for pid: pid_t) -> String? {
        if let app = NSRunningApplication(processIdentifier: pid) {
            return app.localizedName ?? app.bundleIdentifier
        }
        return nil
    }
}
