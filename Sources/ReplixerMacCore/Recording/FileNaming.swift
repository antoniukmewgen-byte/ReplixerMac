import Foundation

/// Builds Windows-parity recording file names and resolves the save
/// directory. Naming scheme: {Manager}_{Platform}_{yy.MM.dd}_{HH.mm}, with a
/// _{ss} suffix appended only if that exact name already exists (collision)
/// — mirrors Replixer's Windows naming scheme.
///
/// `Manager` has no settings-backed value yet (that's Phase 2) — using the
/// macOS account name (`NSUserName()`) as a placeholder, since it's the
/// closest available stand-in for "whoever is using this Mac" until real
/// settings exist.
public enum FileNaming {
    static var recordingsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReplixerMac", isDirectory: true)
            .appendingPathComponent("Recordings", isDirectory: true)
    }

    static func ensureRecordingsDirectoryExists() throws {
        try FileManager.default.createDirectory(at: recordingsDirectory, withIntermediateDirectories: true)
    }

    /// Returns a fresh, non-colliding URL under `recordingsDirectory` for a
    /// new recording. `date` and `manager` are parameters (not just defaults)
    /// so tests/other callers can pin them deterministically.
    ///
    /// `manager` defaults to `AppSettings.shared.managerName` (Phase 2.1) —
    /// itself defaulted to `NSUserName()` until a settings UI exists
    /// (Phase 7) to change it to something else.
    static func recordingURL(platform: String, date: Date = Date(), manager: String = AppSettings.shared.managerName) -> URL {
        let minuteFormatter = DateFormatter()
        minuteFormatter.dateFormat = "yy.MM.dd_HH.mm"
        let base = "\(manager)_\(platform)_\(minuteFormatter.string(from: date))"

        let directory = recordingsDirectory
        let candidate = directory.appendingPathComponent("\(base).m4a")
        if !FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }

        let secondsFormatter = DateFormatter()
        secondsFormatter.dateFormat = "ss"
        let withSeconds = "\(base)_\(secondsFormatter.string(from: date))"
        return directory.appendingPathComponent("\(withSeconds).m4a")
    }

    /// Sibling path used while a recording is still in progress — deliberately
    /// distinct from the final name so an interrupted recording (crash,
    /// force-quit, `kill -9`) is never mistaken for a complete, playable file.
    /// AudioMixerEncoder renames this to the real name only after a clean
    /// stop() (i.e. after the IOProc is torn down and the AVAudioFile has
    /// finalized its container).
    ///
    /// The `.inprogress` marker is inserted *before* the real extension
    /// (`foo.inprogress.m4a`), not appended after it (`foo.m4a.inprogress`).
    /// AVAudioFile infers the container format purely from the URL's last
    /// path extension at creation time — writing to a URL whose last
    /// extension is `.inprogress` silently produces the wrong container
    /// (not proper MPEG-4), which then fails to open once simply renamed to
    /// `.m4a`, even though every sample was written successfully. Keeping
    /// `.m4a` as the actual last extension throughout recording avoids that.
    static func partialURL(for finalURL: URL) -> URL {
        let ext = finalURL.pathExtension
        return finalURL.deletingPathExtension()
            .appendingPathExtension("inprogress")
            .appendingPathExtension(ext)
    }

    /// Removes any leftover `.inprogress` files in the recordings directory —
    /// remnants of a recording that was interrupted before AudioMixerEncoder
    /// could rename it to its final name. Mirrors the Windows
    /// CleanupStaleTempFiles behavior. Safe to call unconditionally at
    /// startup: an `.inprogress` file is by definition never a properly
    /// finalized recording, so there's nothing worth salvaging from it.
    public static func cleanupStalePartialFiles() {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: recordingsDirectory, includingPropertiesForKeys: nil
        ) else { return }

        for url in entries where url.deletingPathExtension().pathExtension == "inprogress" {
            do {
                try FileManager.default.removeItem(at: url)
                print("[FileNaming] 🧹 видалив застарілий незавершений запис: \(url.lastPathComponent)")
            } catch {
                print("[FileNaming] ⚠️ не вдалося видалити \(url.lastPathComponent): \(error)")
            }
        }
    }
}
