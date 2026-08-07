import AppKit
import CoreAudio
import Foundation

/// Step B smoke test for Phase 1.1 — creates a CATapDescription-based
/// process tap for a single process and immediately destroys it again.
/// No aggregate device, no IOProc, no file I/O. Purpose: isolate the
/// single biggest unknown (does the macOS 14.2+ process-tap API even
/// compile and succeed the way we expect) before building anything on
/// top of it.
enum ProcessTapSmokeTest {
    static func findTelegramProcessObjectID() -> AudioObjectID? {
        let processIDs: [AudioObjectID] = CAObject.readArray(
            AudioObjectID(kAudioObjectSystemObject),
            .processObjectList
        )

        for objectID in processIDs {
            guard let pid: pid_t = CAObject.read(objectID, .processPID) else { continue }
            guard let app = NSRunningApplication(processIdentifier: pid) else { continue }
            let name = app.localizedName ?? app.bundleIdentifier ?? ""
            if name.contains("Telegram") { return objectID }
        }
        return nil
    }

    static func run(processObjectID: AudioObjectID) {
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
