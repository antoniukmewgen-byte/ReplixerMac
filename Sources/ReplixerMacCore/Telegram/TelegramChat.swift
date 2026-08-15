import Foundation

/// A named Telegram destination (chat, optionally a specific forum topic
/// within it) recordings/reports can be sent to. Windows parity source:
/// `Models/TelegramChat.cs` (`record TelegramChat(string Name, long Id,
/// int? TopicId = null)`), ported as a plain `Hashable`/`Identifiable`
/// struct so `ProfileView`'s chat `Picker` can bind directly to it (same
/// role `TelegramChat.ToString() => Name` plays for WPF's `ComboBox`).
///
/// **`chatId`/`topicId` are TDLib's own values, NOT Windows' `AppSecrets.cs`
/// integers.** Windows' `TelegramUploadService` talks to Telegram via
/// WTelegram (raw MTProto); mac's `TelegramAuthClient`/`TelegramUploadService`
/// talk to it via TDLib, which represents supergroup/channel chat ids
/// differently (conventionally prefixed `-100`) — the bare positive
/// integers in Windows' `AppSecrets.TelegramChats` are not directly usable
/// here. Read the real values off via `--telegram-list-chats-smoke-test`
/// (`TelegramChatListSmokeTest`, which dumps every chat TDLib knows about
/// next to its title) and hand-fill `AppSecrets.telegramChats` — see that
/// property's doc comment.
public struct TelegramChat: Hashable, Identifiable {
    public let name: String
    public let chatId: Int64
    public let topicId: Int?

    // `name` rather than `chatId`, deliberately: two entries could in
    // principle share a TDLib chat id with different topic ids (distinct
    // forum topics inside the same supergroup), and `name` is already
    // required to be a unique human-readable label for the picker, so it
    // doubles as a stable `Identifiable` key without risking a collision
    // `chatId` alone couldn't rule out.
    public var id: String { name }

    public init(name: String, chatId: Int64, topicId: Int? = nil) {
        self.name = name
        self.chatId = chatId
        self.topicId = topicId
    }
}
