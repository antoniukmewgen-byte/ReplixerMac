import AppKit
import CoreAudio
import Foundation

/// Polls the CoreAudio HAL process list once a second and reports a call as
/// "active" when a known messenger process (see `SupportedMessenger`) has
/// both input (mic) and output (speaker) IO running at the same time — same
/// heuristic Phase 1 validated for Telegram, now generalized (Phase 3)
/// across all Windows-parity target apps instead of just one.
///
/// Windows parity source: `MicrophoneMonitorService` — including its
/// single-active-call assumption. Tracks at most one active messenger at a
/// time (first match wins per poll, matching Windows' single
/// `_isCallActive`/`_activeApp`); two different messengers ringing
/// simultaneously isn't a scenario either build handles.
final class CallMonitor {
    var onCallStarted: ((_ messenger: SupportedMessenger, _ processName: String) -> Void)?
    var onCallEnded: ((_ messenger: SupportedMessenger, _ processName: String) -> Void)?

    private var activeMessenger: SupportedMessenger?
    private var pollTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.replixer.call-monitor")

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

        // Collect every matching messenger process first, rather than
        // acting on the first match found and stopping there. With more
        // than one target app installed, a messenger's process object can
        // linger in the HAL's list with stale IO state even when it's not
        // in a call (observed on a real device: Viber sitting at
        // input=false/output=true indefinitely after being idle) — bailing
        // out on that first, inactive match would mean never reaching a
        // genuinely active messenger (e.g. WhatsApp) listed after it.
        var matches: [(messenger: SupportedMessenger, name: String, micAndSpeakerActive: Bool)] = []
        for objectID in processIDs {
            guard let pid: pid_t = CAObject.read(objectID, .processPID) else { continue }
            guard let name = processName(for: pid),
                  let messenger = SupportedMessenger.matching(processName: name) else { continue }

            let isRunningInput: UInt32 = CAObject.read(objectID, .processIsRunningInput) ?? 0
            let isRunningOutput: UInt32 = CAObject.read(objectID, .processIsRunningOutput) ?? 0
            matches.append((messenger, name, isRunningInput != 0 && isRunningOutput != 0))
        }

        if let activeMessenger {
            // A call is already tracked as active — only care whether that
            // specific messenger still shows mic+speaker both running.
            // Ignoring other messengers' matches here on purpose: two
            // different messengers ringing at once isn't handled (see type
            // doc), so once one is active it keeps priority until it ends.
            if let stillActive = matches.first(where: { $0.messenger == activeMessenger }),
               stillActive.micAndSpeakerActive {
                return
            }
            self.activeMessenger = nil
            let endedName = matches.first(where: { $0.messenger == activeMessenger })?.name ?? activeMessenger.rawValue
            onCallEnded?(activeMessenger, endedName)
            return
        }

        // No call tracked yet — the first messenger found with mic+speaker
        // both active starts one.
        if let newlyActive = matches.first(where: { $0.micAndSpeakerActive }) {
            activeMessenger = newlyActive.messenger
            onCallStarted?(newlyActive.messenger, newlyActive.name)
        }
    }

    /// Prefer the running application's localized/bundle name over the raw
    /// CoreAudio bundle-ID property, since e.g. Telegram Desktop (Qt) and
    /// the native macOS client register under different bundle identifiers.
    private func processName(for pid: pid_t) -> String? {
        if let app = NSRunningApplication(processIdentifier: pid) {
            return app.localizedName ?? app.bundleIdentifier
        }
        return nil
    }
}
