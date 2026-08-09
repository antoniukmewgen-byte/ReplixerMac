import Foundation

/// The messenger apps CallMonitor watches for via CoreAudio process activity.
/// Windows parity source: `MicrophoneMonitorService._targetProcesses` /
/// `MessengerProcessNames.cs` — same four platforms, same substring-match
/// approach (a packaged app's process name can carry a prefix/suffix the
/// exact display name doesn't have, so `contains` rather than exact
/// equality — same reasoning Windows uses).
///
/// `rawValue` doubles as the platform label used in file names
/// (`FileNaming.recordingURL(platform:)`) and `RecordingHistory` entries
/// (Windows parity: `RecordingEntry.Platform` is also just this string), and
/// as the substring matched against the running process's localized name.
///
/// Only Telegram has been verified end-to-end against a real macOS call so
/// far (Phase 1-2). WhatsApp/Viber/Ringostat are wired up per the plan but
/// unverified — in particular, Electron-based WhatsApp on macOS may run its
/// audio under a helper/renderer process whose name doesn't contain
/// "WhatsApp", the same failure mode Windows hit with Store-packaged
/// WhatsApp (worked around there with a UWP-host + window-title fallback in
/// `MessengerProcessNames.cs`). If that turns out to be the case here too,
/// this enum's `matching(processName:)` is the place to add an analogous
/// fallback — not addressed yet since it needs a real device test first.
public enum SupportedMessenger: String, CaseIterable {
    case telegram = "Telegram"
    case whatsApp = "WhatsApp"
    case viber = "Viber"
    case ringostat = "Ringostat"

    /// Returns the messenger whose substring appears in `processName`, if
    /// any. First match wins when iterating `allCases` (declaration order)
    /// — mirrors Windows' `_targetProcesses.FirstOrDefault`, which likewise
    /// doesn't define behavior for two target apps matching at once.
    static func matching(processName: String) -> SupportedMessenger? {
        allCases.first { processName.localizedCaseInsensitiveContains($0.rawValue) }
    }
}
