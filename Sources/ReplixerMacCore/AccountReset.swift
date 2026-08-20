import Foundation

/// Windows parity: `ProfileViewModel.ClearAllData()` — wipes every stored
/// integration credential/connection plus the Telegram session and the
/// recording-history metadata file, then leaves the caller with a clean
/// `AppSettings` (`isSetupComplete = false`) to relaunch into
/// `SetupWizardView`. Deliberately narrow, matching Windows' own scope
/// exactly: the actual recorded audio files, missed-call queues/history, the
/// pending-upload retry queue, the error-report queue, and screenshots are
/// all left untouched — only `ProfileView`'s "Небезпечна зона" button calls
/// this, and its warning text reflects the same scope.
///
/// Pure data wipe only — no confirmation dialog, no app relaunch/termination.
/// Those are UI/app-lifecycle concerns that belong in `ProfileView`
/// (`ReplixerMacApp` target), not here.
public enum AccountReset {
    public static func clearAllData() {
        TelegramAuthClient.logout()

        if FileManager.default.fileExists(atPath: RecordingHistory.store.url.path) {
            try? FileManager.default.removeItem(at: RecordingHistory.store.url)
        }

        let settings = AppSettings.shared
        settings.isTelegramEnabled = false
        settings.telegramChatId = nil
        settings.telegramTopicId = nil
        settings.telegramPhone = nil
        settings.isGoogleDriveEnabled = false
        settings.googleDriveFolderId = nil
        settings.googleDriveUserFolderId = nil
        settings.isDriveConnected = false
        settings.managerName = ""
        settings.position = "Менеджер"
        settings.isKommoEnabled = false
        settings.kommoSubdomain = nil
        settings.kommoApiToken = nil
        settings.isKommoConnected = false
        settings.isGoogleSheetsEnabled = false
        settings.googleSheetsId = nil
        settings.googleSheetsTabName = nil
        settings.isSheetsConnected = false
        settings.isSetupComplete = false
        settings.flush()
    }
}
