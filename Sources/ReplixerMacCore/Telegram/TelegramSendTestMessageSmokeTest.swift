import Foundation
import TDLibKit

/// Phase 4.2 diagnostic — validates chat/topic *targeting* (does
/// `sendMessage` actually land where `AppSettings.telegramChatId`/
/// `telegramTopicId` point?) with a cheap text message, before wiring up
/// the real recording upload (which additionally has to deal with file
/// transfer, captions, retry-on-failure — no need to debug all of that at
/// once). Mirrors `TelegramChatListSmokeTest`'s "reuse the already-
/// authenticated client" shape.
public enum TelegramSendTestMessageSmokeTest {
    public static func run() async {
        guard let chatId = AppSettings.shared.telegramChatId else {
            print("[\(timestamp())] ❌ У налаштуваннях (\(AppSettings.store.url.path)) не заповнено telegramChatId — дізнайся id потрібного чату через --telegram-list-chats-smoke-test і впиши його в settings.json.")
            return
        }
        let topicId = AppSettings.shared.telegramTopicId

        let authClient = TelegramAuthClient()
        do {
            try await authClient.login()
        } catch TelegramAuthError.missingCredentials {
            print("[\(timestamp())] ❌ У налаштуваннях (\(AppSettings.store.url.path)) не заповнені telegramApiId/telegramApiHash — додай їх (значення з https://my.telegram.org) і спробуй знову.")
            return
        } catch {
            print("[\(timestamp())] ❌ Авторизація провалилась: \(error)")
            return
        }

        let client = authClient.client!

        let messageText = "✅ ReplixerMac: тестове повідомлення (\(timestamp()))"
        let content = InputMessageContent.inputMessageText(InputMessageText(
            clearDraft: false,
            linkPreviewOptions: nil,
            text: FormattedText(entities: [], text: messageText)
        ))
        // Only forum-supergroup topics are relevant here — Windows'
        // TopicId is nil for most of the six configured chats and set for
        // the rest, same optionality carried over via
        // AppSettings.telegramTopicId.
        let messageTopic: MessageTopic? = topicId.map { .messageTopicForum(MessageTopicForum(forumTopicId: $0)) }

        do {
            let sent = try await client.sendMessage(
                chatId: chatId,
                inputMessageContent: content,
                options: nil,
                replyMarkup: nil,
                replyTo: nil,
                topicId: messageTopic
            )
            print("[\(timestamp())] ✅ Повідомлення надіслано у chatId=\(chatId)\(topicId.map { " (topicId=\($0))" } ?? "") — messageId=\(sent.id).")
        } catch {
            print("[\(timestamp())] ❌ Не вдалось надіслати повідомлення у chatId=\(chatId)\(topicId.map { " (topicId=\($0))" } ?? ""): \(error)")
        }

        authClient.shutdown()
    }
}
