import Foundation

/// Persisted app settings — Codable, saved via `JSONStore` (debounced,
/// atomic). Windows-parity source: Replixer's `AppSettings.cs`, but scoped
/// down to what Phase 2 actually needs right now — fields for not-yet-built
/// integrations (Telegram upload, Google Drive, Kommo, Sheets) will be
/// added in their own phases instead of stubbed out ahead of time.
///
/// No settings UI exists yet (that's Phase 7). Until then, `managerName`
/// defaults to the macOS account name (the same placeholder `FileNaming`
/// used directly before this phase) and can be changed by hand-editing the
/// JSON file at `AppSettings.store.url` — the file is created with defaults
/// on first run specifically so there's something to find and edit.
public final class AppSettings: Codable {
    public static let shared = AppSettings.load()

    public static let store = JSONStore<AppSettings>(url:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReplixerMac", isDirectory: true)
            .appendingPathComponent("settings.json")
    )

    // Read externally (main.swift logs it at startup) and, since Phase 7.3,
    // written externally too — SettingsView (ReplixerMacApp target) is the
    // first real settings UI, so the setter is fully public now.
    public var managerName: String {
        didSet { AppSettings.store.scheduleSave(self) }
    }

    // Phase 4, revised post-Phase-7.6: my.telegram.org app credentials,
    // required by setTdlibParameters before TDLib will do anything. Now
    // matches Windows exactly — `AppSecrets.telegramApiId`/`telegramApiHash`
    // are build-time constants (see `TelegramAuthClient.login()`'s doc
    // comment), not per-user settings, since a Telegram *application*
    // registration is shared across every manager using this build, same
    // "one shared credential, not one per user" reasoning as the Google
    // service account above.

    // Phase 4.2: which chat (and, for forum-mode supergroups, which topic
    // within it) recordings get sent to. Windows' equivalent
    // (`AppSettings.TelegramChatId`/`TelegramTopicId`) is populated by
    // picking from a hardcoded `AppSecrets.TelegramChats` list in a setup
    // wizard ComboBox (gated by the user's `Position`) — `ProfileView`'s
    // Telegram section now has the same picker (over `AppSecrets
    // .telegramChats`, filtered via `PositionPolicy.filteredTelegramChats`),
    // which writes here on selection. These two properties still hold
    // TDLib's own chat ids (note these are NOT the same integers as
    // Windows' AppSecrets.cs — TDLib prefixes supergroup/channel ids with
    // "-100"; `--telegram-list-chats-smoke-test` is what reads off the real
    // value for a given chat name to hand-fill into `AppSecrets
    // .telegramChats`). telegramTopicId is Int (not Int64) to match TDLib's
    // `MessageTopicForum.forumTopicId: Int`.
    public var telegramChatId: Int64? {
        didSet { AppSettings.store.scheduleSave(self) }
    }
    public var telegramTopicId: Int? {
        didSet { AppSettings.store.scheduleSave(self) }
    }

    // Phase 7.8: Windows parity `AppSettings.TelegramPhone` — the phone
    // number entered into `TelegramAuthSection`'s "Авторизувати" flow,
    // persisted so the field is pre-filled next time (SetupWizardView or
    // ProfileView) rather than asking again on every reauthorize. Purely a
    // UI convenience: `TelegramAuthClient.login(phone:inputHandler:)` takes
    // the phone as a direct parameter each time, it doesn't read this field
    // itself.
    public var telegramPhone: String? {
        didSet { AppSettings.store.scheduleSave(self) }
    }

    // Phase 12: Windows parity `ProfileViewModel.IsTelegramEnabled` — same
    // opt-out-on-top-of-presence reasoning as isGoogleDriveEnabled above,
    // just for the Telegram leg (gates on top of telegramChatId presence).
    public var isTelegramEnabled: Bool {
        didSet { AppSettings.store.scheduleSave(self) }
    }

    // Phase 5, revised post-Phase-7.6: Google Drive upload. Now matches
    // Windows exactly — the service-account JSON itself is a build-time
    // constant (`AppSecrets.googleServiceAccountJson`, see
    // `GoogleServiceAccountAuth`'s doc comment), not a per-user setting, so
    // there's no path/credential field here at all anymore. Destination
    // Drive folder id (the part of the folder's URL after `folders/`) is
    // the only Drive-related thing left for the user to configure. Public
    // since Phase 7.6 (ProfileView's Google Drive section).
    public var googleDriveFolderId: String? {
        didSet { AppSettings.store.scheduleSave(self) }
    }

    // Phase 12: Windows parity `ProfileViewModel.IsGoogleDriveEnabled` — a
    // real opt-out toggle on top of folder-id presence. Before this, Drive
    // upload was gated purely by "is googleDriveFolderId set" — there was
    // no way to temporarily pause the integration without clearing (and
    // later re-typing) the folder id. Defaults to true: an opt-*out*
    // toggle, matching Windows' own default, since the folder-id-presence
    // gate already prevents upload attempts on a fresh install with nothing
    // configured yet.
    public var isGoogleDriveEnabled: Bool {
        didSet { AppSettings.store.scheduleSave(self) }
    }

    // Windows parity: `AppSettings.UserFolderId` — the Drive id of the
    // per-manager subfolder created (once) inside `googleDriveFolderId`,
    // cached here so every subsequent upload reuses it instead of re-
    // querying Drive's `Files.List` on every single recording.
    // `GoogleDriveUploadService.resolveManagerFolder()` is the only writer;
    // it's `nil` until the first successful resolve. Not reset automatically
    // if `managerName` changes later — same "stale cache until something
    // explicitly clears it" behavior Windows has (ProfileView's account-
    // reset flow is the only thing that clears `UserFolderId` there).
    public var googleDriveUserFolderId: String? {
        didSet { AppSettings.store.scheduleSave(self) }
    }

    // Persists the last "Перевірити з'єднання" outcome for Drive, so
    // ProfileView can show a green "Доступ підключено" label as soon as the
    // screen appears — not just for the rest of the current app session.
    // Written by ProfileView.testDriveConnection() on every check (true on
    // success, false on failure); also reset to false whenever
    // `googleDriveFolderId` is edited, since a stale green label for a
    // folder id nobody has actually verified yet would be misleading.
    public var isDriveConnected: Bool {
        didSet { AppSettings.store.scheduleSave(self) }
    }

    // Phase 7.7: gates whether `SetupWizardView` shows on launch. Windows-
    // parity source: `AppSettings.IsSetupComplete`, but mac's wizard is
    // scoped down to just confirming `managerName` (see that view's doc
    // comment for why Position/Kommo/Sheets/the Telegram chat-picker don't
    // carry over) — completing it just means "the welcome screen has been
    // dismissed once", not "every integration is configured".
    public var isSetupComplete: Bool {
        didSet { AppSettings.store.scheduleSave(self) }
    }

    // Phase 8.2: launch-at-login toggle, mirrored into the real launchd
    // registration by AutoStartManager.setEnabled (SettingsView calls both
    // together — this field alone doesn't register anything, same "plain
    // data, no side effects of its own" role AppSettings' other fields
    // play). Defaults to false: opting into background/login-launch
    // behavior should be a deliberate choice, not silently on for a
    // fresh install.
    public var isAutoStartEnabled: Bool {
        didSet { AppSettings.store.scheduleSave(self) }
    }

    // Phase 10.0: manager's role, gating call-report field visibility via
    // PositionPolicy — Windows parity source: AppSettings.cs's `Position`.
    // Defaults to "Менеджер" (Windows' own default), the only role with
    // every report field visible. Also gates `ProfileView`'s Telegram chat
    // `Picker` (`PositionPolicy.filteredTelegramChats`, added Phase 7.6) —
    // unlike Windows, that picker doesn't live in the setup wizard at all
    // (see `SetupWizardView`'s doc comment on why Position/the chat picker
    // stay out of it), only in Profile/Settings.
    public var position: String {
        didSet { AppSettings.store.scheduleSave(self) }
    }

    // Phase 10.1a: Kommo CRM — subdomain (the part before `.kommo.com`) and
    // a long-lived API token, Windows parity source: AppSettings.cs's
    // `KommoSubdomain`/`KommoApiToken`.
    public var kommoSubdomain: String? {
        didSet { AppSettings.store.scheduleSave(self) }
    }
    public var kommoApiToken: String? {
        didSet { AppSettings.store.scheduleSave(self) }
    }

    // Phase 12: Windows parity `ProfileViewModel.IsKommoEnabled` — a real
    // opt-out toggle on top of subdomain/token presence. Supersedes the
    // Phase 10.1a doc comment's "presence of both required fields IS the
    // enabled signal" stance above (kept working correctly until now, but
    // gave no way to pause the integration without clearing saved
    // credentials) — see isGoogleDriveEnabled above for the same reasoning.
    public var isKommoEnabled: Bool {
        didSet { AppSettings.store.scheduleSave(self) }
    }

    // Same persisted-status role as `isDriveConnected` above, for Kommo's
    // own "Перевірити з'єднання" button — reset to false whenever
    // `kommoSubdomain`/`kommoApiToken` is edited.
    public var isKommoConnected: Bool {
        didSet { AppSettings.store.scheduleSave(self) }
    }

    // Phase 10.1c: Kommo's "робочий час" (working-hours) processing-speed
    // field needs the same configurable workday window Windows exposes as
    // `AppSettings.WorkDayStart`/`WorkDayEnd` (`TimeSpan`, defaults 9:00/
    // 21:00). Stored as minutes-since-midnight (Int, not TimeSpan/Date —
    // Foundation has no lightweight "time of day" type, and minutes is
    // trivial to turn into a `DatePicker`-friendly `Date` in SettingsView
    // without dragging a specific calendar day along with it). Defaults
    // match Windows' `TimeSpan.FromHours(9)`/`FromHours(21)` exactly.
    public var workDayStartMinutes: Int {
        didSet { AppSettings.store.scheduleSave(self) }
    }
    public var workDayEndMinutes: Int {
        didSet { AppSettings.store.scheduleSave(self) }
    }

    // Phase 15: Google Sheets — a second, independent missed-call delivery
    // leg alongside Kommo (`MissedCallDeliveryService`), not used by the
    // regular recording-upload path. Windows parity source: AppSettings.cs's
    // `IsGoogleSheetsEnabled`/`GoogleSheetsId`/`GoogleSheetsTabName`
    // (`GoogleSheetsId` accepts either a bare spreadsheet id or a full
    // Sheets URL — `ProfileView`'s field applies the same
    // `extractSpreadsheetId` sanitization on every edit Windows'
    // `ProfileViewModel.ExtractSpreadsheetId` does). `googleSheetsTabName`
    // empty/nil means "first/default tab" (`GoogleSheetsUploadService`
    // treats a blank sheet name as "no `SheetName!`-prefix on the range").
    // Defaults to false/opt-in, same reasoning as isKommoEnabled — there's
    // no shared-across-every-build credential here (unlike Drive/Telegram),
    // so a fresh install has nothing configured and shouldn't silently
    // attempt delivery.
    public var isGoogleSheetsEnabled: Bool {
        didSet { AppSettings.store.scheduleSave(self) }
    }
    public var googleSheetsId: String? {
        didSet { AppSettings.store.scheduleSave(self) }
    }
    public var googleSheetsTabName: String? {
        didSet { AppSettings.store.scheduleSave(self) }
    }

    // Same persisted-status role as `isDriveConnected`/`isKommoConnected`
    // above, for Sheets' own "Перевірити з'єднання" button — reset to false
    // whenever `googleSheetsId`/`googleSheetsTabName` is edited. Windows'
    // `AppSettings.IsGoogleSheetsConnected` is nullable (`bool?`); kept as a
    // plain non-optional `Bool` here instead, matching this file's own
    // established convention for `isDriveConnected`/`isKommoConnected`
    // rather than Windows' tri-state shape — "never checked" and "checked,
    // failed" both just render as the same "not connected" UI state either
    // way.
    public var isSheetsConnected: Bool {
        didSet { AppSettings.store.scheduleSave(self) }
    }

    // Windows parity: `AppSettings.IsNotificationsEnabled` — gates
    // `NotificationService`'s toast stack (see NotificationService.swift).
    // Defaults to true, matching Windows' own default and this field's
    // "opt-out, not opt-in" framing (toasts are a UX nicety on by default,
    // not a per-integration credential a fresh install has nothing
    // configured for).
    public var isNotificationsEnabled: Bool {
        didSet { AppSettings.store.scheduleSave(self) }
    }

    private enum CodingKeys: String, CodingKey {
        case managerName
        case telegramChatId
        case telegramTopicId
        case telegramPhone
        case isTelegramEnabled
        case googleDriveFolderId
        case googleDriveUserFolderId
        case isGoogleDriveEnabled
        case isDriveConnected
        case isSetupComplete
        case isAutoStartEnabled
        case position
        case kommoSubdomain
        case kommoApiToken
        case isKommoEnabled
        case isKommoConnected
        case workDayStartMinutes
        case workDayEndMinutes
        case isGoogleSheetsEnabled
        case googleSheetsId
        case googleSheetsTabName
        case isSheetsConnected
        case isNotificationsEnabled
    }

    private init(managerName: String, telegramChatId: Int64? = nil, telegramTopicId: Int? = nil, telegramPhone: String? = nil, isTelegramEnabled: Bool = true, googleDriveFolderId: String? = nil, googleDriveUserFolderId: String? = nil, isGoogleDriveEnabled: Bool = true, isDriveConnected: Bool = false, isSetupComplete: Bool = false, isAutoStartEnabled: Bool = false, position: String = "Менеджер", kommoSubdomain: String? = nil, kommoApiToken: String? = nil, isKommoEnabled: Bool = true, isKommoConnected: Bool = false, workDayStartMinutes: Int = 9 * 60, workDayEndMinutes: Int = 21 * 60, isGoogleSheetsEnabled: Bool = false, googleSheetsId: String? = nil, googleSheetsTabName: String? = nil, isSheetsConnected: Bool = false, isNotificationsEnabled: Bool = true) {
        self.managerName = managerName
        self.telegramChatId = telegramChatId
        self.telegramTopicId = telegramTopicId
        self.telegramPhone = telegramPhone
        self.isTelegramEnabled = isTelegramEnabled
        self.googleDriveFolderId = googleDriveFolderId
        self.googleDriveUserFolderId = googleDriveUserFolderId
        self.isGoogleDriveEnabled = isGoogleDriveEnabled
        self.isDriveConnected = isDriveConnected
        self.isSetupComplete = isSetupComplete
        self.isAutoStartEnabled = isAutoStartEnabled
        self.position = position
        self.kommoSubdomain = kommoSubdomain
        self.kommoApiToken = kommoApiToken
        self.isKommoEnabled = isKommoEnabled
        self.isKommoConnected = isKommoConnected
        self.workDayStartMinutes = workDayStartMinutes
        self.workDayEndMinutes = workDayEndMinutes
        self.isGoogleSheetsEnabled = isGoogleSheetsEnabled
        self.googleSheetsId = googleSheetsId
        self.googleSheetsTabName = googleSheetsTabName
        self.isSheetsConnected = isSheetsConnected
        self.isNotificationsEnabled = isNotificationsEnabled
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // decodeIfPresent (not decode) so adding a new field later can't
        // break loading an older settings.json that predates it.
        managerName = try container.decodeIfPresent(String.self, forKey: .managerName) ?? NSUserName()
        telegramChatId = try container.decodeIfPresent(Int64.self, forKey: .telegramChatId)
        telegramTopicId = try container.decodeIfPresent(Int.self, forKey: .telegramTopicId)
        telegramPhone = try container.decodeIfPresent(String.self, forKey: .telegramPhone)
        // Missing key means this settings.json predates Phase 12 — default
        // true (opt-out semantics: an existing install with a chat already
        // configured was implicitly "enabled" before this flag existed).
        isTelegramEnabled = try container.decodeIfPresent(Bool.self, forKey: .isTelegramEnabled) ?? true
        googleDriveFolderId = try container.decodeIfPresent(String.self, forKey: .googleDriveFolderId)
        googleDriveUserFolderId = try container.decodeIfPresent(String.self, forKey: .googleDriveUserFolderId)
        isGoogleDriveEnabled = try container.decodeIfPresent(Bool.self, forKey: .isGoogleDriveEnabled) ?? true
        isDriveConnected = try container.decodeIfPresent(Bool.self, forKey: .isDriveConnected) ?? false
        // Missing key means this settings.json predates Phase 7.7 — true
        // "fresh install" (the file was just bootstrapped, nothing
        // configured yet) should still show the wizard, but an existing
        // dev/test install that already has Telegram chat or Drive wired up
        // clearly already went through informal "setup"; don't make it
        // re-click through a welcome screen it has no memory of skipping.
        isSetupComplete = try container.decodeIfPresent(Bool.self, forKey: .isSetupComplete)
            ?? (telegramChatId != nil || googleDriveFolderId != nil)
        // Missing key means this settings.json predates Phase 8.2 — default
        // to false (not to whatever SMAppService.mainApp.status happens to
        // report) since a decode is plain data loading, not the place to
        // reach out to launchd; AppSettings.load()'s only caller context is
        // app startup, where SettingsView hasn't even rendered yet to show
        // a mismatch if there were one.
        isAutoStartEnabled = try container.decodeIfPresent(Bool.self, forKey: .isAutoStartEnabled) ?? false
        position = try container.decodeIfPresent(String.self, forKey: .position) ?? "Менеджер"
        kommoSubdomain = try container.decodeIfPresent(String.self, forKey: .kommoSubdomain)
        kommoApiToken = try container.decodeIfPresent(String.self, forKey: .kommoApiToken)
        isKommoEnabled = try container.decodeIfPresent(Bool.self, forKey: .isKommoEnabled) ?? true
        isKommoConnected = try container.decodeIfPresent(Bool.self, forKey: .isKommoConnected) ?? false
        workDayStartMinutes = try container.decodeIfPresent(Int.self, forKey: .workDayStartMinutes) ?? 9 * 60
        workDayEndMinutes = try container.decodeIfPresent(Int.self, forKey: .workDayEndMinutes) ?? 21 * 60
        isGoogleSheetsEnabled = try container.decodeIfPresent(Bool.self, forKey: .isGoogleSheetsEnabled) ?? false
        googleSheetsId = try container.decodeIfPresent(String.self, forKey: .googleSheetsId)
        googleSheetsTabName = try container.decodeIfPresent(String.self, forKey: .googleSheetsTabName)
        isSheetsConnected = try container.decodeIfPresent(Bool.self, forKey: .isSheetsConnected) ?? false
        isNotificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .isNotificationsEnabled) ?? true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(managerName, forKey: .managerName)
        try container.encode(telegramChatId, forKey: .telegramChatId)
        try container.encode(telegramTopicId, forKey: .telegramTopicId)
        try container.encode(telegramPhone, forKey: .telegramPhone)
        try container.encode(isTelegramEnabled, forKey: .isTelegramEnabled)
        try container.encode(googleDriveFolderId, forKey: .googleDriveFolderId)
        try container.encode(googleDriveUserFolderId, forKey: .googleDriveUserFolderId)
        try container.encode(isGoogleDriveEnabled, forKey: .isGoogleDriveEnabled)
        try container.encode(isDriveConnected, forKey: .isDriveConnected)
        try container.encode(isSetupComplete, forKey: .isSetupComplete)
        try container.encode(isAutoStartEnabled, forKey: .isAutoStartEnabled)
        try container.encode(position, forKey: .position)
        try container.encode(kommoSubdomain, forKey: .kommoSubdomain)
        try container.encode(kommoApiToken, forKey: .kommoApiToken)
        try container.encode(isKommoEnabled, forKey: .isKommoEnabled)
        try container.encode(isKommoConnected, forKey: .isKommoConnected)
        try container.encode(workDayStartMinutes, forKey: .workDayStartMinutes)
        try container.encode(workDayEndMinutes, forKey: .workDayEndMinutes)
        try container.encode(isGoogleSheetsEnabled, forKey: .isGoogleSheetsEnabled)
        try container.encode(googleSheetsId, forKey: .googleSheetsId)
        try container.encode(googleSheetsTabName, forKey: .googleSheetsTabName)
        try container.encode(isSheetsConnected, forKey: .isSheetsConnected)
        try container.encode(isNotificationsEnabled, forKey: .isNotificationsEnabled)
    }

    private static func load() -> AppSettings {
        switch store.load() {
        case .decoded(let loaded):
            return loaded

        case .notFound:
            let defaults = AppSettings(managerName: NSUserName())
            // Bootstrap the file on first run so `store.url` has something
            // in it to find and hand-edit, rather than only appearing after
            // the first real settings change (which, until Phase 7 ships a
            // UI, might be never).
            store.saveNow(defaults)
            return defaults

        case .decodeFailed(let error):
            // Do NOT fall back to bootstrapping defaults here — that would
            // immediately saveNow() a fresh all-nil AppSettings over the
            // existing file, silently destroying whatever was already in
            // it (managerName, telegramChatId, etc.) just because one
            // hand-edited field had a typo. Fail loud instead: print
            // exactly what didn't parse and stop, so the JSON can be fixed
            // by hand without losing anything.
            print("[AppSettings] ❌ не вдалося прочитати \(store.url.path): \(error)")
            print("[AppSettings] Файл НЕ буде перезаписано — виправ помилку в JSON вручну і запусти знову.")
            exit(1)
        }
    }

    /// Forces any pending debounced save to happen immediately — call
    /// before process exit so a change made right before shutdown isn't
    /// lost. Unused until a later phase actually mutates settings at
    /// runtime, but wired into the signal handlers now (main.swift) so it
    /// doesn't need to be remembered later.
    public func flush() {
        AppSettings.store.saveNow(self)
    }
}
