import Foundation
import TDLibKit

/// Phase 4.2 diagnostic — mirrors `AudioProcessListSmokeTest`'s "let the
/// real API tell us the truth instead of guessing" approach from Phase 3.
///
/// Windows' `AppSecrets.cs` hardcodes a list of target chats as
/// (Name, Id: long, TopicId: int?) — those `Id` values come from
/// WTelegram (raw MTProto), a different library than TDLib. It is not
/// known whether those bare positive integers are usable as-is as TDLib's
/// `chat_id` (which for supergroups/channels is conventionally a
/// "-100"-prefixed value) or need conversion. Rather than guess/derive a
/// conversion formula, this dumps every chat TDLib itself knows about —
/// its own `id` next to the human-readable `title` — so the real chat_id
/// for each Windows-configured chat name can just be read off directly.
///
/// First run (main list only) found none of the Windows-configured chat
/// names — turned out those chats are archived and/or filed into chat
/// folders on this account, both of which TDLib treats as separate chat
/// lists (`.chatListArchive` / `.chatListFolder`) that `.chatListMain`
/// alone never surfaces. This now walks all three.
public enum TelegramChatListSmokeTest {
    public static func run() async {
        let authClient = TelegramAuthClient()
        do {
            try await authClient.login()
        } catch TelegramAuthError.missingCredentials {
            print("[\(timestamp())] ❌ AppSecrets.telegramApiId/telegramApiHash не заповнені в цій збірці — додай їх (значення з https://my.telegram.org) в Sources/ReplixerMacCore/GoogleDrive/AppSecrets.swift і спробуй знову.")
            return
        } catch {
            print("[\(timestamp())] ❌ Авторизація провалилась: \(error)")
            return
        }

        let client = authClient.client!

        // updateChatFolders is pushed asynchronously right around
        // authorizationStateReady, not guaranteed to have already arrived
        // the instant login() resumes — give it a moment before reading
        // authClient.chatFolders below, otherwise folders can be missed on
        // a fast run.
        try? await Task.sleep(nanoseconds: 1_000_000_000)

        await listChats(client: client, chatList: .chatListMain, label: "Основний список")
        await listChats(client: client, chatList: .chatListArchive, label: "Архів")

        if authClient.chatFolders.isEmpty {
            print("[\(timestamp())] Папок (chat folders) не знайдено.")
        }
        for folder in authClient.chatFolders {
            let label = "Папка \"\(folder.name.text.text)\" (id \(folder.id))"
            await listChats(client: client, chatList: .chatListFolder(ChatListFolder(chatFolderId: folder.id)), label: label)
        }

        authClient.shutdown()
    }

    /// Loads (paging in via `loadChats`, same "nothing more to load" 404 is
    /// benign — reasoning as before) and prints every chat in one
    /// `ChatList`, prefixed with `label` so the source list is obvious in
    /// the output when a chat's real id doesn't match any Windows-
    /// configured name.
    private static func listChats(client: TDLibClient, chatList: ChatList, label: String) async {
        do {
            for _ in 0..<5 {
                _ = try? await client.loadChats(chatList: chatList, limit: 100)
            }

            let chats = try await client.getChats(chatList: chatList, limit: 200)
            print("[\(timestamp())] \(label): \(chats.chatIds.count) чат(ів). id — title:")
            for chatId in chats.chatIds {
                do {
                    let chat = try await client.getChat(chatId: chatId)
                    print("  \(chat.id)\t\(chat.title)")
                } catch {
                    print("  \(chatId)\t(не вдалось отримати назву: \(error))")
                }
            }
        } catch {
            print("[\(timestamp())] ❌ \(label): не вдалось отримати список чатів: \(error)")
        }
    }
}
