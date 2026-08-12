import AppKit
import CoreAudio
import Foundation

/// Polls the CoreAudio HAL process list once a second and reports a call as
/// "active" when a known messenger process (see `SupportedMessenger`) has
/// both input (mic) and output (speaker) IO running at the same time — same
/// heuristic Phase 1 validated for Telegram, now generalized (Phase 3)
/// across all Windows-parity target apps instead of just one. Once a call is
/// active, ending it is deliberately a looser check (mic *or* speaker still
/// running keeps it alive) than starting one (mic *and* speaker) — see
/// `poll()`'s two branches — so muting the mic mid-call doesn't read as the
/// call ending.
///
/// Windows parity source: `MicrophoneMonitorService` — including its
/// single-active-call assumption and its asymmetric start-vs-continue
/// signal combination. Tracks at most one active messenger at a
/// time (first match wins per poll, matching Windows' single
/// `_isCallActive`/`_activeApp`); two different messengers ringing
/// simultaneously isn't a scenario either build handles.
public final class CallMonitor {
    // Explicit public init required: an implicit default init is always
    // internal-access, even on a public class — main.swift (a different
    // target) needs to be able to construct one.
    public init() {}

    public var onCallStarted: ((_ messenger: SupportedMessenger, _ processName: String) -> Void)?
    public var onCallEnded: ((_ messenger: SupportedMessenger, _ processName: String) -> Void)?

    private var activeMessenger: SupportedMessenger?
    private var pollTimer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.replixer.call-monitor")

    public func start() {
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
        //
        // mic/speaker are tracked separately (not pre-ANDed here) because
        // starting vs. continuing a call use different combinations below —
        // Windows parity: MicrophoneMonitorService.PollCallback.
        var matches: [(messenger: SupportedMessenger, name: String, micActive: Bool, speakerActive: Bool)] = []
        for objectID in processIDs {
            guard let pid: pid_t = CAObject.read(objectID, .processPID) else { continue }
            guard let name = processName(for: pid),
                  let messenger = SupportedMessenger.matching(processName: name) else { continue }

            let isRunningInput: UInt32 = CAObject.read(objectID, .processIsRunningInput) ?? 0
            let isRunningOutput: UInt32 = CAObject.read(objectID, .processIsRunningOutput) ?? 0
            matches.append((messenger, name, isRunningInput != 0, isRunningOutput != 0))
        }

        if let activeMessenger {
            // A call is already tracked as active — only care whether that
            // specific messenger still shows *either* signal running.
            // Windows parity: PollCallback's continuation branch ends the
            // call only when `!micActive && !audioActive` — i.e. it takes
            // losing *both* mic and speaker to call it over, not just one.
            // Muting the mic mid-call (isRunningInput drops to 0 while the
            // app keeps rendering the other side's audio) must not read as
            // "call ended" on its own — using AND here (like the start
            // check below) would do exactly that.
            if let stillActive = matches.first(where: { $0.messenger == activeMessenger }),
               stillActive.micActive || stillActive.speakerActive {
                return
            }
            self.activeMessenger = nil
            let endedName = matches.first(where: { $0.messenger == activeMessenger })?.name ?? activeMessenger.rawValue
            onCallEnded?(activeMessenger, endedName)
            return
        }

        // No call tracked yet — starting one still requires mic+speaker
        // *both* active (Windows parity: PollCallback's initial-detection
        // branch), unlike the continuation check above. Only requiring one
        // signal here would false-positive on a messenger simply playing a
        // notification/ringtone sound (speaker-only, no call).
        if let newlyActive = matches.first(where: { $0.micActive && $0.speakerActive }) {
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
