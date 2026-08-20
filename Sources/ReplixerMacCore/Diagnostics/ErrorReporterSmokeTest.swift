import Foundation

/// Phase 14 diagnostic — exercises the exact same `ErrorReporter.report`
/// path a real upload/recording failure would hit (formatting, chunking,
/// the "· Replixer MacOS" tag, live `AppSettings` integration-status line,
/// and — on success — nothing left queued; on failure — a real entry
/// written to `error_queue.json` for the next `flushQueue()` to retry),
/// rather than a bare `curl` that only proves the bot token/chat id work in
/// isolation. Mirrors `TelegramSendTestMessageSmokeTest`'s "cheap synthetic
/// message through the real send path" shape.
public enum ErrorReporterSmokeTest {
    public static func run() async {
        guard !AppSecrets.errorBotToken.isEmpty else {
            print("[\(timestamp())] ❌ AppSecrets.errorBotToken порожній у цій збірці — впиши реальний токен бота в Sources/ReplixerMacCore/GoogleDrive/AppSecrets.swift і спробуй знову.")
            return
        }
        guard !AppSecrets.errorChatIds.isEmpty else {
            print("[\(timestamp())] ❌ AppSecrets.errorChatIds порожній у цій збірці — впиши хоча б один chat id в Sources/ReplixerMacCore/GoogleDrive/AppSecrets.swift і спробуй знову.")
            return
        }
        print("[\(timestamp())] Надсилаю тестовий звіт через ErrorReporter.report(...) у \(AppSecrets.errorChatIds.count) чат(и)...")
        await ErrorReporter.shared.report(
            category: "SMOKE_TEST",
            message: "Це тестове повідомлення від --error-reporter-smoke-test — якщо воно дійшло, ErrorReporter повністю працює.")
        print("[\(timestamp())] Готово. Перевір Telegram — якщо повідомлення не прийшло, воно, найімовірніше, залишилось у черзі на диску (error_queue.json у Application Support) через мережеву помилку; наступний flushQueue() (кожні 5хв під час звичайного запуску застосунку) спробує ще раз.")
    }
}
