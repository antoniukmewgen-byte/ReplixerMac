import Foundation

/// Phase 7.1 target-split fix: `main.swift` (now in the separate
/// `ReplixerMacCallPoC` executable target) defines its own top-level
/// `formatter`/`timestamp()` for its own log lines — but several smoke-test
/// files that moved into this `ReplixerMacCore` library target
/// (`TelegramChatListSmokeTest`, `TelegramSendAudioSmokeTest`,
/// `TelegramSendTestMessageSmokeTest`, `GoogleDriveFolderAccessSmokeTest`,
/// `GoogleDriveUploadSmokeTest`) call a bare `timestamp()` too. Top-level
/// code in a file is only accessible within its own module, so once those
/// files moved to a different target than main.swift, that reference would
/// no longer resolve. This is a standalone, functionally identical copy
/// scoped to this module — main.swift's own copy is untouched.
private let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
}()

func timestamp() -> String {
    formatter.string(from: Date())
}
