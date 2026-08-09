import Foundation

/// Phase 5.1 diagnostic — parity with Windows'
/// `GoogleDriveUploadService.TestFolderAccessAsync`: verifies service-account
/// auth (JWT sign + token exchange, `GoogleServiceAccountAuth`) and Drive
/// folder access both work end to end against the real Drive API, as the
/// first checkpoint before any upload code exists (Step 5.2).
enum GoogleDriveFolderAccessSmokeTest {
    static func run() async {
        guard let folderId = AppSettings.shared.googleDriveFolderId else {
            print("[\(timestamp())] ❌ У налаштуваннях (\(AppSettings.store.url.path)) не заповнено googleDriveFolderId.")
            return
        }

        print("[\(timestamp())] Отримую access token через service account...")
        let accessToken: String
        do {
            accessToken = try await GoogleServiceAccountAuth.fetchAccessToken()
        } catch GoogleServiceAccountAuth.AuthError.missingSettings {
            print("[\(timestamp())] ❌ У налаштуваннях (\(AppSettings.store.url.path)) не заповнено googleServiceAccountPath.")
            return
        } catch GoogleServiceAccountAuth.AuthError.fileNotFound(let path) {
            print("[\(timestamp())] ❌ Файл service account не знайдено: \(path)")
            return
        } catch {
            print("[\(timestamp())] ❌ Не вдалося отримати access token: \(error)")
            return
        }
        print("[\(timestamp())] ✅ access token отримано.")

        guard var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(folderId)") else {
            print("[\(timestamp())] ❌ Некоректний googleDriveFolderId: \(folderId)")
            return
        }
        components.queryItems = [
            URLQueryItem(name: "fields", value: "id,name,mimeType"),
            URLQueryItem(name: "supportsAllDrives", value: "true")
        ]
        guard let url = components.url else {
            print("[\(timestamp())] ❌ Не вдалося зібрати URL запиту до Drive API.")
            return
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let bodyText = String(data: data, encoding: .utf8) ?? "<нечитабельно>"
            guard let http = response as? HTTPURLResponse else {
                print("[\(timestamp())] ❌ Неочікувана відповідь без HTTP статусу.")
                return
            }
            if (200...299).contains(http.statusCode) {
                print("[\(timestamp())] ✅ Доступ до теки Drive підтверджено: \(bodyText)")
            } else {
                print("[\(timestamp())] ❌ Drive API повернув статус \(http.statusCode): \(bodyText)")
            }
        } catch {
            print("[\(timestamp())] ❌ Запит до Drive API провалився: \(error)")
        }
    }
}
