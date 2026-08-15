import Foundation

/// Template for `AppSecrets.swift` — copy this file to `AppSecrets.swift`
/// (same directory) and fill in real values before building. `AppSecrets
/// .swift` is git-ignored (see `.gitignore`), so it never lands in the
/// repo; this `.example.swift` file is the tracked stand-in that documents
/// its shape, mirroring Windows' `Infrastructure/AppSecrets.cs` /
/// `AppSecrets.example.cs` pair exactly.
///
/// Populate `googleServiceAccountJson` from CI the same way Windows does —
/// a build step writes the real `AppSecrets.swift` from a
/// `GOOGLE_CREDENTIALS_JSON`-style secret before `swift build` runs — or
/// just hand-fill it locally for a dev build.
// `public` because `telegramChats` below is read from ProfileView.swift in
// the separate ReplixerMacApp module/target — `internal` (Swift's default)
// doesn't cross a module boundary. The other members are deliberately left
// non-public; nothing outside ReplixerMacCore needs them directly.
public enum AppSecrets {
    /// my.telegram.org application credentials, required by TDLib's
    /// `setTdlibParameters` before any Telegram operation works. Windows
    /// parity: `AppSecrets.TelegramApiId`/`TelegramApiHash`. `0`/`""` here
    /// means "not configured" — `TelegramAuthClient.login()` throws
    /// `.missingCredentials` when `telegramApiId` is `0`.
    static let telegramApiId = 0
    static let telegramApiHash = ""

    /// Named Telegram send destinations shown in `ProfileView`'s chat
    /// picker. Windows parity: `AppSecrets.TelegramChats`, but the ids
    /// below are TDLib chat ids (conventionally `-100`-prefixed for
    /// supergroups/channels), NOT the bare positive `long`s Windows uses —
    /// WTelegram (Windows) and TDLib (mac) represent the same chat's id
    /// differently. Discover real values via
    /// `--telegram-list-chats-smoke-test` and fill this in per-deployment.
    /// Empty here means "no chats configured" — `ProfileView`'s picker
    /// shows no options until this is populated.
    public static let telegramChats: [TelegramChat] = []

    /// Full contents of a Google service-account `service_account.json` key
    /// file, minified to a single line. Empty string here means "not
    /// configured" — `GoogleServiceAccountAuth.fetchAccessToken()` throws
    /// `.missingSecret` when this is empty, same as Windows' `AppSecrets
    /// .GoogleServiceAccountJson` defaulting to `""`.
    static let googleServiceAccountJson = ""
}
