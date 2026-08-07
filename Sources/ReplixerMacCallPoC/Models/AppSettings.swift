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
final class AppSettings: Codable {
    static let shared = AppSettings.load()

    static let store = JSONStore<AppSettings>(url:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReplixerMac", isDirectory: true)
            .appendingPathComponent("settings.json")
    )

    var managerName: String {
        didSet { AppSettings.store.scheduleSave(self) }
    }

    // Phase 4: my.telegram.org app credentials, required by
    // setTdlibParameters before TDLib will do anything. Unlike managerName,
    // these have no sane default — nil until hand-edited into settings.json
    // (same "no UI yet, edit the JSON" pattern as managerName), and
    // TelegramAuthClient refuses to start login without both present.
    var telegramApiId: Int? {
        didSet { AppSettings.store.scheduleSave(self) }
    }
    var telegramApiHash: String? {
        didSet { AppSettings.store.scheduleSave(self) }
    }

    private enum CodingKeys: String, CodingKey {
        case managerName
        case telegramApiId
        case telegramApiHash
    }

    private init(managerName: String, telegramApiId: Int? = nil, telegramApiHash: String? = nil) {
        self.managerName = managerName
        self.telegramApiId = telegramApiId
        self.telegramApiHash = telegramApiHash
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // decodeIfPresent (not decode) so adding a new field later can't
        // break loading an older settings.json that predates it.
        managerName = try container.decodeIfPresent(String.self, forKey: .managerName) ?? NSUserName()
        telegramApiId = try container.decodeIfPresent(Int.self, forKey: .telegramApiId)
        telegramApiHash = try container.decodeIfPresent(String.self, forKey: .telegramApiHash)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(managerName, forKey: .managerName)
        try container.encode(telegramApiId, forKey: .telegramApiId)
        try container.encode(telegramApiHash, forKey: .telegramApiHash)
    }

    private static func load() -> AppSettings {
        if let loaded = store.load() {
            return loaded
        }
        let defaults = AppSettings(managerName: NSUserName())
        // Bootstrap the file on first run so `store.url` has something in
        // it to find and hand-edit, rather than only appearing after the
        // first real settings change (which, until Phase 7 ships a UI,
        // might be never).
        store.saveNow(defaults)
        return defaults
    }

    /// Forces any pending debounced save to happen immediately — call
    /// before process exit so a change made right before shutdown isn't
    /// lost. Unused until a later phase actually mutates settings at
    /// runtime, but wired into the signal handlers now (main.swift) so it
    /// doesn't need to be remembered later.
    func flush() {
        AppSettings.store.saveNow(self)
    }
}
