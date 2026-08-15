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
    // every report field visible; unlike Windows this never gates a
    // hardcoded Telegram-chat picker (mac has no such picker — see
    // SetupWizardView's doc comment), it only feeds PositionPolicy.
    public var position: String {
        didSet { AppSettings.store.scheduleSave(self) }
    }

    // Phase 10.1a: Kommo CRM — subdomain (the part before `.kommo.com`) and
    // a long-lived API token, Windows parity source: AppSettings.cs's
    // `KommoSubdomain`/`KommoApiToken`. Unlike Windows, there's no separate
    // `IsKommoEnabled` flag here — same "presence of both required fields
    // IS the enabled signal" convention `telegramConfigured`
    // (CallRecordingCoordinator) already uses for Telegram, rather than a
    // redundant boolean that could drift out of sync with them. No cached
    // `IsKommoConnected` either, matching how Drive's own "test connection"
    // result (ProfileView's `driveTestResult`) already stays UI-local
    // @State instead of persisted.
    public var kommoSubdomain: String? {
        didSet { AppSettings.store.scheduleSave(self) }
    }
    public var kommoApiToken: String? {
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

    private enum CodingKeys: String, CodingKey {
        case managerName
        case telegramChatId
        case telegramTopicId
        case googleDriveFolderId
        case isSetupComplete
        case isAutoStartEnabled
        case position
        case kommoSubdomain
        case kommoApiToken
        case workDayStartMinutes
        case workDayEndMinutes
    }

    private init(managerName: String, telegramChatId: Int64? = nil, telegramTopicId: Int? = nil, googleDriveFolderId: String? = nil, isSetupComplete: Bool = false, isAutoStartEnabled: Bool = false, position: String = "Менеджер", kommoSubdomain: String? = nil, kommoApiToken: String? = nil, workDayStartMinutes: Int = 9 * 60, workDayEndMinutes: Int = 21 * 60) {
        self.managerName = managerName
        self.telegramChatId = telegramChatId
        self.telegramTopicId = telegramTopicId
        self.googleDriveFolderId = googleDriveFolderId
        self.isSetupComplete = isSetupComplete
        self.isAutoStartEnabled = isAutoStartEnabled
        self.position = position
        self.kommoSubdomain = kommoSubdomain
        self.kommoApiToken = kommoApiToken
        self.workDayStartMinutes = workDayStartMinutes
        self.workDayEndMinutes = workDayEndMinutes
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // decodeIfPresent (not decode) so adding a new field later can't
        // break loading an older settings.json that predates it.
        managerName = try container.decodeIfPresent(String.self, forKey: .managerName) ?? NSUserName()
        telegramChatId = try container.decodeIfPresent(Int64.self, forKey: .telegramChatId)
        telegramTopicId = try container.decodeIfPresent(Int.self, forKey: .telegramTopicId)
        googleDriveFolderId = try container.decodeIfPresent(String.self, forKey: .googleDriveFolderId)
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
        workDayStartMinutes = try container.decodeIfPresent(Int.self, forKey: .workDayStartMinutes) ?? 9 * 60
        workDayEndMinutes = try container.decodeIfPresent(Int.self, forKey: .workDayEndMinutes) ?? 21 * 60
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(managerName, forKey: .managerName)
        try container.encode(telegramChatId, forKey: .telegramChatId)
        try container.encode(telegramTopicId, forKey: .telegramTopicId)
        try container.encode(googleDriveFolderId, forKey: .googleDriveFolderId)
        try container.encode(isSetupComplete, forKey: .isSetupComplete)
        try container.encode(isAutoStartEnabled, forKey: .isAutoStartEnabled)
        try container.encode(position, forKey: .position)
        try container.encode(kommoSubdomain, forKey: .kommoSubdomain)
        try container.encode(kommoApiToken, forKey: .kommoApiToken)
        try container.encode(workDayStartMinutes, forKey: .workDayStartMinutes)
        try container.encode(workDayEndMinutes, forKey: .workDayEndMinutes)
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
