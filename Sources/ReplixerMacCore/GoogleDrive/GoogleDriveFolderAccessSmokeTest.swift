import Foundation

/// Phase 5.1 diagnostic — parity with Windows'
/// `GoogleDriveUploadService.TestFolderAccessAsync`: verifies service-account
/// auth (JWT sign + token exchange, `GoogleServiceAccountAuth`) and Drive
/// folder access both work end to end against the real Drive API, as the
/// first checkpoint before any upload code exists (Step 5.2).
///
/// `run()` is the original CLI form (`--gdrive-folder-access-smoke-test`),
/// printing progress as it goes. Phase 7.6 needs the same check from
/// Profile's "Перевірити з'єднання" button, but a UI button can't usefully
/// consume stdout — `check()` is that same logic reshaped to return one
/// final result instead, with `run()` now just printing whatever `check()`
/// comes back with so the two never drift apart.
public enum GoogleDriveFolderAccessSmokeTest {
    /// Stand-in for `Swift.Result<String, String>` — the stdlib `Result`
    /// requires its `Failure` type to conform to `Error`, which a plain
    /// `String` doesn't, so a bare `Result<String, String>` return type
    /// fails to compile. Every failure mode here is just a Ukrainian
    /// message meant for direct display, not a typed error to catch/match
    /// on, so a two-case enum is a better fit than wrapping the message in
    /// a throwaway `Error` conformance just to keep using `Result`.
    public enum CheckOutcome {
        case success(String)
        case failure(String)
    }

    public static func run() async {
        switch await check() {
        case .success(let message):
            print("[\(timestamp())] ✅ \(message)")
        case .failure(let message):
            print("[\(timestamp())] ❌ \(message)")
        }
    }

    /// Non-interactive (no stdin involved anywhere in this call chain,
    /// unlike `TelegramAuthClient.login()`) — safe to wire directly to a UI
    /// button. Returns a human-readable Ukrainian message on either side
    /// rather than throwing, since the caller (a button handler) wants to
    /// display *something* for every failure mode, not just the ones it
    /// happened to anticipate.
    public static func check() async -> CheckOutcome {
        guard let folderId = AppSettings.shared.googleDriveFolderId else {
            return .failure("У налаштуваннях (\(AppSettings.store.url.path)) не заповнено googleDriveFolderId.")
        }

        let accessToken: String
        do {
            accessToken = try await GoogleServiceAccountAuth.fetchAccessToken()
        } catch GoogleServiceAccountAuth.AuthError.missingSecret {
            return .failure("AppSecrets.googleServiceAccountJson не заповнено в цій збірці.")
        } catch {
            return .failure("Не вдалося отримати access token: \(error)")
        }

        guard var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files/\(folderId)") else {
            return .failure("Некоректний googleDriveFolderId: \(folderId)")
        }
        components.queryItems = [
            URLQueryItem(name: "fields", value: "id,name,mimeType"),
            URLQueryItem(name: "supportsAllDrives", value: "true")
        ]
        guard let url = components.url else {
            return .failure("Не вдалося зібрати URL запиту до Drive API.")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let bodyText = String(data: data, encoding: .utf8) ?? "<нечитабельно>"
            guard let http = response as? HTTPURLResponse else {
                return .failure("Неочікувана відповідь без HTTP статусу.")
            }
            if (200...299).contains(http.statusCode) {
                return .success("Доступ до теки Drive підтверджено: \(bodyText)")
            } else {
                return .failure("Drive API повернув статус \(http.statusCode): \(bodyText)")
            }
        } catch {
            return .failure("Запит до Drive API провалився: \(error)")
        }
    }
}
