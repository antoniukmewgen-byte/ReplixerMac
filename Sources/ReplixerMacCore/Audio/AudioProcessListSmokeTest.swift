import AppKit
import CoreAudio
import Foundation

/// Diagnostic aid for Phase 3: `SupportedMessenger.matching(processName:)`
/// assumes a messenger's CoreAudio process object carries a name containing
/// e.g. "WhatsApp" or "Viber" — true for Telegram (verified end-to-end in
/// Phase 1-2), unverified for the others. If a real call through one of
/// them never triggers `CallMonitor.onCallStarted`, the likely cause is
/// that assumption being wrong (e.g. an Electron helper/renderer process
/// with a different name actually owns the audio, the same failure mode
/// Windows hit with Store-packaged WhatsApp). This dumps every CoreAudio
/// process object that has input or output IO active, with its real name
/// and bundle ID, so the actual name can be read off directly instead of
/// guessed — start it, then place the call during the scan window.
public enum AudioProcessListSmokeTest {
    public static func run(duration: TimeInterval = 45) {
        print("[AudioProcessListSmokeTest] сканую CoreAudio-процеси з активним input/output кожну секунду \(Int(duration))с — зроби дзвінок Viber/WhatsApp зараз, або просто увімкни/вимкни мікрофон/динамік у застосунку, щоб він з'явився нижче.")
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            listActiveProcesses()
            Thread.sleep(forTimeInterval: 1.0)
        }
        print("[AudioProcessListSmokeTest] готово.")
    }

    private static func listActiveProcesses() {
        let processIDs: [AudioObjectID] = CAObject.readArray(
            AudioObjectID(kAudioObjectSystemObject),
            .processObjectList
        )

        for objectID in processIDs {
            guard let pid: pid_t = CAObject.read(objectID, .processPID) else { continue }

            let isRunningInput: UInt32 = CAObject.read(objectID, .processIsRunningInput) ?? 0
            let isRunningOutput: UInt32 = CAObject.read(objectID, .processIsRunningOutput) ?? 0
            guard isRunningInput != 0 || isRunningOutput != 0 else { continue }

            let app = NSRunningApplication(processIdentifier: pid)
            let name = app?.localizedName ?? "?"
            let bundleID = app?.bundleIdentifier ?? "?"
            print("[AudioProcessListSmokeTest] pid=\(pid) name=\"\(name)\" bundleID=\"\(bundleID)\" input=\(isRunningInput != 0) output=\(isRunningOutput != 0)")
        }
    }
}
