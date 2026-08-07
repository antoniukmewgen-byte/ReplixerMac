import Foundation
import TDLibKit

/// Phase 4.2 diagnostic — the file-sending counterpart to
/// `TelegramSendTestMessageSmokeTest`: exercises `TelegramUploadService`'s
/// actual send path (InputMessageAudio + caption + retry) against a real
/// local recording, before `CallRecordingCoordinator` gets wired up to call
/// it automatically once a call ends.
enum TelegramSendAudioSmokeTest {
    static func run(filePath: String) async {
        guard FileManager.default.fileExists(atPath: filePath) else {
            print("[\(timestamp())] ❌ Файл не знайдено: \(filePath)")
            return
        }

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

        let fileName = (filePath as NSString).lastPathComponent
        do {
            let messageId = try await TelegramUploadService.sendRecording(
                filePath: filePath,
                caption: "Запис дзвінку: \(fileName)",
                client: authClient.client!
            )
            print("[\(timestamp())] ✅ Аудіофайл надіслано — messageId=\(messageId).")
        } catch TelegramUploadService.UploadError.missingChatId {
            print("[\(timestamp())] ❌ У налаштуваннях (\(AppSettings.store.url.path)) не заповнено telegramChatId.")
        } catch {
            print("[\(timestamp())] ❌ Не вдалось надіслати файл: \(error)")
        }

        authClient.shutdown()
    }
}
