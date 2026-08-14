import Foundation

/// Phase 5.2: uploads a local file to a Google Drive folder via the Drive
/// REST API's resumable-upload protocol, authenticated through
/// `GoogleServiceAccountAuth`. Windows-parity source:
/// `GoogleDriveUploadService.cs`'s `UploadAsync`/`TryUploadOnceAsync` — the
/// .NET Google API client library there picks simple-vs-resumable upload
/// automatically; no equivalent client library exists on macOS (plan's
/// known risk #5), so resumable is used unconditionally here. That's not a
/// downgrade: call recordings routinely exceed the 5MB simple-upload
/// ceiling once a call runs past a few minutes.
///
/// Deliberately NOT ported yet (deferred, not silently dropped): the
/// Windows original's process-lifetime shared rate-limit cooldown across
/// every upload call site, and `GetOrCreateUserFolderAsync`'s per-manager
/// subfolders. Both only start mattering once a background retry service
/// exists (Phase 6) hitting this repeatedly on a timer — this single-shot
/// "one retry after a short delay" shape (same as `TelegramUploadService`)
/// is enough for the live-call upload path this phase builds.
enum GoogleDriveUploadService {
    enum UploadError: Swift.Error {
        case missingFolderId
        case couldNotReadFileSize
        case initiateSessionFailed(String)
        case missingUploadLocation
        case uploadFailed(String)
    }

    /// Uploads `filePath` into `AppSettings.shared.googleDriveFolderId`.
    /// Returns the uploaded file's `webViewLink` — used for the
    /// "💾 Google Drive: {url}" caption line `TelegramUploadService.buildCaption`
    /// already knows how to append once Step 5.3 wires this in.
    ///
    /// Retries exactly once, after a fixed 5s delay, on any thrown error —
    /// same "one retry, then surface the failure" shape as
    /// `TelegramUploadService.sendRecording`.
    static func upload(filePath: String, isRetry: Bool = false) async throws -> String {
        guard let folderId = AppSettings.shared.googleDriveFolderId else {
            throw UploadError.missingFolderId
        }

        do {
            let accessToken = try await GoogleServiceAccountAuth.fetchAccessToken()
            let sessionURL = try await initiateResumableSession(filePath: filePath, folderId: folderId, accessToken: accessToken)
            return try await uploadFileBytes(filePath: filePath, sessionURL: sessionURL)
        } catch {
            guard !isRetry else { throw error }
            print("[GoogleDriveUploadService] ⚠️ завантаження не вдалось (\(error)), повторна спроба через 5с...")
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return try await upload(filePath: filePath, isRetry: true)
        }
    }

    /// Step 1 of the resumable-upload protocol: POST the file's metadata
    /// (name + destination folder) and get back a session URL (in the
    /// response's `Location` header) that the actual bytes get PUT to next.
    /// `fields=id,webViewLink` on the query string carries through to the
    /// final response after the PUT completes, so `uploadFileBytes` doesn't
    /// need a separate follow-up GET to read those back.
    private static func initiateResumableSession(filePath: String, folderId: String, accessToken: String) async throws -> URL {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: filePath),
              let fileSize = attributes[.size] as? Int else {
            throw UploadError.couldNotReadFileSize
        }
        let fileName = (filePath as NSString).lastPathComponent

        var components = URLComponents(string: "https://www.googleapis.com/upload/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "uploadType", value: "resumable"),
            URLQueryItem(name: "fields", value: "id,webViewLink"),
            // Without this, Drive silently can't see a folder living on a
            // Shared Drive as a valid `parents` target and reports it as
            // 404 "File not found" for the folder id — same reasoning as
            // GoogleDriveFolderAccessSmokeTest's identical query param,
            // just missed here originally.
            URLQueryItem(name: "supportsAllDrives", value: "true")
        ]
        guard let url = components.url else {
            throw UploadError.initiateSessionFailed("не вдалося зібрати URL ініціалізації сесії.")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        request.setValue(mimeType(forPath: filePath), forHTTPHeaderField: "X-Upload-Content-Type")
        request.setValue("\(fileSize)", forHTTPHeaderField: "X-Upload-Content-Length")

        let metadata: [String: Any] = ["name": fileName, "parents": [folderId]]
        request.httpBody = try JSONSerialization.data(withJSONObject: metadata)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bodyText = String(data: data, encoding: .utf8) ?? "<нечитабельно>"
            throw UploadError.initiateSessionFailed("статус \(status): \(bodyText)")
        }
        guard let locationString = http.value(forHTTPHeaderField: "Location"), let location = URL(string: locationString) else {
            throw UploadError.missingUploadLocation
        }
        return location
    }

    /// Step 2: PUT the actual file bytes to the session URL from step 1.
    /// Uploaded as a single PUT (not chunked) — realistic recording sizes
    /// (minutes to low tens of MB of AAC) don't need resumable's
    /// chunk-and-resume-on-failure capability, just its higher size
    /// ceiling; the retry-once wrapper in `upload(filePath:isRetry:)`
    /// covers transient failures instead.
    private static func uploadFileBytes(filePath: String, sessionURL: URL) async throws -> String {
        var request = URLRequest(url: sessionURL)
        request.httpMethod = "PUT"
        request.setValue(mimeType(forPath: filePath), forHTTPHeaderField: "Content-Type")

        let fileURL = URL(fileURLWithPath: filePath)
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: fileURL)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bodyText = String(data: data, encoding: .utf8) ?? "<нечитабельно>"
            throw UploadError.uploadFailed("статус \(status): \(bodyText)")
        }

        struct UploadedFile: Decodable {
            let id: String
            let webViewLink: String?
        }
        let uploaded = try JSONDecoder().decode(UploadedFile.self, from: data)
        // webViewLink should always be present given `fields=id,webViewLink`
        // above, but fall back to constructing the standard viewer URL from
        // the id rather than throwing, if Drive ever omits it.
        return uploaded.webViewLink ?? "https://drive.google.com/file/d/\(uploaded.id)/view"
    }

    private static func mimeType(forPath path: String) -> String {
        // Recordings are always .m4a (AAC) per FileNaming/AudioMixerEncoder;
        // Phase 11.5 adds missed-call screenshots (.png, see
        // `ScreenCaptureService`) as this upload path's second caller — no
        // need for a fuller extension→MIME lookup table beyond these two.
        if path.hasSuffix(".m4a") { return "audio/mp4" }
        if path.hasSuffix(".png") { return "image/png" }
        return "application/octet-stream"
    }
}
