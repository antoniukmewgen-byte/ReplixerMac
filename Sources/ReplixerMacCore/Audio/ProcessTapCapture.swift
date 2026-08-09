import AppKit
import CoreAudio
import Foundation

/// Step B smoke test for Phase 1.1 — creates a CATapDescription-based
/// process tap for a single process and immediately destroys it again.
/// No aggregate device, no IOProc, no file I/O. Purpose: isolate the
/// single biggest unknown (does the macOS 14.2+ process-tap API even
/// compile and succeed the way we expect) before building anything on
/// top of it.
public enum ProcessTapSmokeTest {
    public static func findTelegramProcessObjectID() -> AudioObjectID? {
        findProcessObjectID(for: .telegram)
    }

    /// Phase 3: generalized version of the above, used by
    /// `CallRecordingCoordinator` for all supported messengers, not just
    /// Telegram. Re-scans the CoreAudio HAL process list rather than
    /// reusing any AudioObjectID `CallMonitor` might have seen during
    /// polling — a process object's AudioObjectID isn't guaranteed stable
    /// across separate calls, so it's always re-resolved fresh at the
    /// moment a call actually starts.
    static func findProcessObjectID(for messenger: SupportedMessenger) -> AudioObjectID? {
        let processIDs: [AudioObjectID] = CAObject.readArray(
            AudioObjectID(kAudioObjectSystemObject),
            .processObjectList
        )

        for objectID in processIDs {
            guard let pid: pid_t = CAObject.read(objectID, .processPID) else { continue }
            guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
            let name = app.localizedName ?? app.bundleIdentifier ?? ""
            if name.localizedCaseInsensitiveContains(messenger.rawValue) { return objectID }
        }
        return nil
    }

    public static func run(processObjectID: AudioObjectID) {
        print("[ProcessTapSmokeTest] creating tap for process object \(processObjectID)...")

        let tapDescription = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        tapDescription.isPrivate = true
        tapDescription.muteBehavior = .unmuted

        var tapID = AudioObjectID.unknown
        let createStatus = AudioHardwareCreateProcessTap(tapDescription, &tapID)

        guard createStatus == noErr else {
            print("[ProcessTapSmokeTest] ❌ AudioHardwareCreateProcessTap failed, OSStatus=\(createStatus)")
            return
        }

        print("[ProcessTapSmokeTest] ✅ tap created, id=\(tapID). Destroying immediately...")

        let destroyStatus = AudioHardwareDestroyProcessTap(tapID)
        if destroyStatus == noErr {
            print("[ProcessTapSmokeTest] ✅ tap destroyed cleanly.")
        } else {
            print("[ProcessTapSmokeTest] ⚠️ AudioHardwareDestroyProcessTap failed, OSStatus=\(destroyStatus)")
        }
    }
}
