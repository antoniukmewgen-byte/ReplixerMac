import Foundation

/// Phase 5.2 diagnostic — the Drive-upload counterpart to
/// `TelegramSendAudioSmokeTest`: exercises `GoogleDriveUploadService.upload`
/// end to end against a real local file, before `CallRecordingCoordinator`
/// gets wired up to call it automatically alongside the Telegram upload
/// (Step 5.3).
public enum GoogleDriveUploadSmokeTest {
    public static func run(filePath: String) async {
        guard FileManager.default.fileExists(atPath: filePath) else {
            print("[\(timestamp())] ❌ Файл не знайдено: \(filePath)")
            return
        }

        print("[\(timestamp())] Завантажую \(filePath) у Google Drive...")
        do {
            let link = try await GoogleDriveUploadService.upload(filePath: filePath)
            print("[\(timestamp())] ✅ Файл завантажено — \(link)")
        } catch GoogleDriveUploadService.UploadError.missingFolderId {
            print("[\(timestamp())] ❌ У налаштуваннях (\(AppSettings.store.url.path)) не заповнено googleDriveFolderId.")
        } catch GoogleServiceAccountAuth.AuthError.missingSecret {
            print("[\(timestamp())] ❌ AppSecrets.googleServiceAccountJson не заповнено в цій збірці.")
        } catch {
            print("[\(timestamp())] ❌ Не вдалося завантажити файл: \(error)")
        }
    }
}
