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

    // Phase 4: my.telegram.org app credentials, required by
    // setTdlibParameters before TDLib will do anything. Unlike managerName,
    // these have no sane default — nil until set. Public since Phase 7.6
    // (ProfileView's Telegram section is the first real UI for these);
    // TelegramAuthClient refuses to start login without both present.
    public var telegramApiId: Int? {
        didSet { AppSettings.store.scheduleSave(self) }
    }
    public var telegramApiHash: String? {
        didSet { AppSettings.store.scheduleSave(self) }
    }

    // Phase 4.2: which chat (and, for forum-mode supergroups, which topic
    // within it) recordings get sent to. Windows' equivalent
    // (`AppSettings.TelegramChatId`/`TelegramTopicId`) is populated by
    // picking from a hardcoded `AppSecrets.TelegramChats` list in a setup
    // wizard ComboBox (gated by the user's `Position`) — that picker is a
    // later phase here (ProfileView's Phase 7.6 fields are plain numeric
    // text entry, not a chat picker yet). Set telegramChatId to one of
    // TDLib's own chat ids (note these are NOT the same integers as
    // Windows' AppSecrets.cs — TDLib prefixes supergroup/channel ids with
    // "-100"; use `--telegram-list-chats-smoke-test` to read off the real
    // value for a given chat name). telegramTopicId is Int (not Int64) to
    // match TDLib's `MessageTopicForum.forumTopicId: Int`.
    public var telegramChatId: Int64? {
        didSet { AppSettings.store.scheduleSave(self) }
    }
    public var telegramTopicId: Int? {
        didSet { AppSettings.store.scheduleSave(self) }
    }

    // Phase 5: Google Drive upload. Unlike Windows (which embeds the
    // service-account JSON as a raw string in a build-time AppSecrets
    // constant), here it's a *path* to a separate service-account JSON file
    // on disk rather than the JSON pasted inline into settings.json —
    // deliberate, to avoid repeating the telegramApiHash null-wipe incident
    // (a multi-hundred-character PEM-embedded JSON string is extremely easy
    // to mis-quote/escape by hand). Point this at wherever the
    // Google-provided `service_account.json` was saved. Public since Phase
    // 7.6 (ProfileView's Google Drive section, with a file picker for this).
    public var googleServiceAccountPath: String? {
        didSet { AppSettings.store.scheduleSave(self) }
    }
    // Destination Drive folder id (the part of the folder's URL after
    // `folders/`) recordings get uploaded into. Public since Phase 7.6, same
    // as googleServiceAccountPath above.
    public var googleDriveFolderId: String? {
        didSet { AppSettings.store.scheduleSave(self) }
    }

    private enum CodingKeys: String, CodingKey {
        case managerName
        case telegramApiId
        case telegramApiHash
        case telegramChatId
        case telegramTopicId
        case googleServiceAccountPath
        case googleDriveFolderId
    }

    private init(managerName: String, telegramApiId: Int? = nil, telegramApiHash: String? = nil, telegramChatId: Int64? = nil, telegramTopicId: Int? = nil, googleServiceAccountPath: String? = nil, googleDriveFolderId: String? = nil) {
        self.managerName = managerName
        self.telegramApiId = telegramApiId
        self.telegramApiHash = telegramApiHash
        self.telegramChatId = telegramChatId
        self.telegramTopicId = telegramTopicId
        self.googleServiceAccountPath = googleServiceAccountPath
        self.googleDriveFolderId = googleDriveFolderId
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // decodeIfPresent (not decode) so adding a new field later can't
        // break loading an older settings.json that predates it.
        managerName = try container.decodeIfPresent(String.self, forKey: .managerName) ?? NSUserName()
        telegramApiId = try container.decodeIfPresent(Int.self, forKey: .telegramApiId)
        telegramApiHash = try container.decodeIfPresent(String.self, forKey: .telegramApiHash)
        telegramChatId = try container.decodeIfPresent(Int64.self, forKey: .telegramChatId)
        telegramTopicId = try container.decodeIfPresent(Int.self, forKey: .telegramTopicId)
        googleServiceAccountPath = try container.decodeIfPresent(String.self, forKey: .googleServiceAccountPath)
        googleDriveFolderId = try container.decodeIfPresent(String.self, forKey: .googleDriveFolderId)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(managerName, forKey: .managerName)
        try container.encode(telegramApiId, forKey: .telegramApiId)
        try container.encode(telegramApiHash, forKey: .telegramApiHash)
        try container.encode(telegramChatId, forKey: .telegramChatId)
        try container.encode(telegramTopicId, forKey: .telegramTopicId)
        try container.encode(googleServiceAccountPath, forKey: .googleServiceAccountPath)
        try container.encode(googleDriveFolderId, forKey: .googleDriveFolderId)
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
            // it (managerName, telegramApiId/Hash, etc.) just because one
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
