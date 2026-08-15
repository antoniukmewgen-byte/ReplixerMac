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
/// Folder structure now matches Windows: `resolveManagerFolder()`/
/// `resolveScreenshotsFolder()` port `GetOrCreateUserFolderAsync`/
/// `ResolveTargetFolderAsync`/`ResolveScreenshotFolderIdAsync` from
/// `GoogleDriveUploadService.cs`/`UploadOrchestrator.cs`/
/// `MissedCallReportViewModel.cs` — see their doc comments below for the
/// exact hierarchy this produces under `AppSettings.shared
/// .googleDriveFolderId` (the user-configured *parent*).
///
/// Deliberately NOT ported yet (deferred, not silently dropped): the
/// Windows original's process-lifetime shared rate-limit cooldown across
/// every upload call site. That only starts mattering once a background
/// retry service exists hitting this repeatedly on a timer — this
/// single-shot "one retry after a short delay" shape (same as
/// `TelegramUploadService`) is enough for the live-call upload path this
/// phase builds.
enum GoogleDriveUploadService {
    enum UploadError: Swift.Error {
        case couldNotReadFileSize
        case initiateSessionFailed(String)
        case missingUploadLocation
        case uploadFailed(String)
        case folderLookupFailed(String)
        case folderCreateFailed(String)
    }

    // MARK: - Folder resolution (Windows parity: ResolveTargetFolderAsync)

    /// The per-manager subfolder living directly inside the user-configured
    /// parent folder (`AppSettings.shared.googleDriveFolderId`) — recordings
    /// get uploaded straight into this folder, same as Windows (no further
    /// "Recordings" subfolder; the manager-name folder *is* the recordings
    /// folder). Named after `AppSettings.shared.managerName` (Windows'
    /// `UserFolderName`, set once at setup from the same field — mac has no
    /// separate copy of it, `managerName` already serves that role).
    ///
    /// Idempotent and cached: `AppSettings.shared.googleDriveUserFolderId`
    /// (Windows' `UserFolderId`) remembers the resolved id so this only
    /// hits the Drive API once per manager, not once per upload. Returns
    /// `nil` only when the parent folder itself isn't configured at all;
    /// every other failure (blank manager name, folder lookup/create
    /// erroring) falls back to the raw parent folder id instead of failing
    /// the whole upload — same "best effort, never block the actual
    /// upload over a convenience folder" stance as Windows'
    /// `ResolveTargetFolderAsync`.
    static func resolveManagerFolder() async -> String? {
        // Sanitizes and self-heals a stray "?hl=ru"-style query string left
        // over from a copy-pasted browser URL — see GoogleDriveFolderId's
        // doc comment for exactly how a corrupted id here silently 404s
        // every upload despite "Перевірити з'єднання" reporting success.
        guard let parentId = GoogleDriveFolderId.sanitizedFromSettings() else { return nil }

        if let cached = AppSettings.shared.googleDriveUserFolderId, !cached.isEmpty {
            return cached
        }

        let managerName = AppSettings.shared.managerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !managerName.isEmpty else { return parentId }

        do {
            let accessToken = try await GoogleServiceAccountAuth.fetchAccessToken()
            let folderId = try await getOrCreateFolder(parentId: parentId, name: managerName, accessToken: accessToken)
            AppSettings.shared.googleDriveUserFolderId = folderId
            return folderId
        } catch {
            print("[GoogleDriveUploadService] ⚠️ не вдалося створити/знайти теку менеджера (\(error)), завантажую напряму у батьківську теку.")
            return parentId
        }
    }

    /// The "Screenshots" subfolder nested under the manager folder (or,
    /// same as Windows' `ResolveBaseFolderId` fallback, directly under the
    /// raw parent if the manager folder hasn't been resolved/created yet —
    /// e.g. a missed-call screenshot happening before any recording has
    /// ever uploaded). `"Screenshots"` is a hardcoded literal here, exactly
    /// like Windows' `MissedCallReportViewModel` — not a per-user setting,
    /// nothing to configure. Same best-effort fallback-to-base-folder
    /// stance as `resolveManagerFolder` above if lookup/create fails.
    static func resolveScreenshotsFolder() async -> String? {
        guard let baseFolderId = await resolveManagerFolder() else { return nil }
        do {
            let accessToken = try await GoogleServiceAccountAuth.fetchAccessToken()
            return try await getOrCreateFolder(parentId: baseFolderId, name: "Screenshots", accessToken: accessToken)
        } catch {
            print("[GoogleDriveUploadService] ⚠️ не вдалося створити/знайти теку Screenshots (\(error)), завантажую напряму у \(baseFolderId).")
            return baseFolderId
        }
    }

    /// Windows parity: `GetOrCreateUserFolderAsync` — idempotent
    /// find-or-create of a named subfolder directly inside `parentId`.
    /// Exposed (not `private`) so a future caller that already has an
    /// access token in hand (or needs a subfolder this type doesn't know
    /// about yet) can reuse it without re-deriving one.
    static func getOrCreateFolder(parentId: String, name: String, accessToken: String) async throws -> String {
        if let existingId = try await findFolder(parentId: parentId, name: name, accessToken: accessToken) {
            return existingId
        }
        return try await createFolder(parentId: parentId, name: name, accessToken: accessToken)
    }

    /// `Files.List` with `q="name='...' and mimeType='...folder' and
    /// '<parentId>' in parents and trashed=false"` — same query Windows
    /// builds in `GetOrCreateUserFolderAsync`, including the
    /// `supportsAllDrives`/`includeItemsFromAllDrives` pair (without them,
    /// Drive silently omits matches living on a Shared Drive rather than
    /// erroring, so a real existing folder there would go undetected and
    /// get needlessly re-created).
    private static func findFolder(parentId: String, name: String, accessToken: String) async throws -> String? {
        // Drive's query-string escaping for a literal single quote inside a
        // string literal — same as Windows' `EscapeQuery`.
        let escapedName = name.replacingOccurrences(of: "'", with: "\\'")
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(
                name: "q",
                value: "name='\(escapedName)' and mimeType='application/vnd.google-apps.folder' and '\(parentId)' in parents and trashed=false"
            ),
            URLQueryItem(name: "fields", value: "files(id,name)"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "true")
        ]
        guard let url = components.url else {
            throw UploadError.folderLookupFailed("не вдалося зібрати URL пошуку теки.")
        }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bodyText = String(data: data, encoding: .utf8) ?? "<нечитабельно>"
            throw UploadError.folderLookupFailed("статус \(status): \(bodyText)")
        }

        struct ListResponse: Decodable {
            struct FileEntry: Decodable { let id: String }
            let files: [FileEntry]
        }
        let decoded = try JSONDecoder().decode(ListResponse.self, from: data)
        return decoded.files.first?.id
    }

    /// `Files.Create` with `mimeType: "application/vnd.google-apps.folder"`
    /// — same metadata shape as Windows' `GetOrCreateUserFolderAsync`.
    private static func createFolder(parentId: String, name: String, accessToken: String) async throws -> String {
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "fields", value: "id"),
            URLQueryItem(name: "supportsAllDrives", value: "true")
        ]
        guard let url = components.url else {
            throw UploadError.folderCreateFailed("не вдалося зібрати URL створення теки.")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        let metadata: [String: Any] = [
            "name": name,
            "mimeType": "application/vnd.google-apps.folder",
            "parents": [parentId]
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: metadata)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let bodyText = String(data: data, encoding: .utf8) ?? "<нечитабельно>"
            throw UploadError.folderCreateFailed("статус \(status): \(bodyText)")
        }

        struct CreatedFile: Decodable { let id: String }
        let created = try JSONDecoder().decode(CreatedFile.self, from: data)
        return created.id
    }

    // MARK: - Upload

    /// Uploads `filePath` into the Drive folder `folderId` — the caller
    /// resolves which folder that is (`resolveManagerFolder()` for
    /// recordings, `resolveScreenshotsFolder()` for screenshots, or a raw
    /// id from a smoke test) before calling this. Returns the uploaded
    /// file's `webViewLink` — used for the "💾 Google Drive: {url}" caption
    /// line `TelegramUploadService.buildCaption` already knows how to
    /// append.
    ///
    /// Retries exactly once, after a fixed 5s delay, on any thrown error —
    /// same "one retry, then surface the failure" shape as
    /// `TelegramUploadService.sendRecording`.
    static func upload(filePath: String, folderId: String, isRetry: Bool = false) async throws -> String {
        do {
            let accessToken = try await GoogleServiceAccountAuth.fetchAccessToken()
            let sessionURL = try await initiateResumableSession(filePath: filePath, folderId: folderId, accessToken: accessToken)
            return try await uploadFileBytes(filePath: filePath, sessionURL: sessionURL)
        } catch {
            guard !isRetry else { throw error }
            print("[GoogleDriveUploadService] ⚠️ завантаження не вдалось (\(error)), повторна спроба через 5с...")
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return try await upload(filePath: filePath, folderId: folderId, isRetry: true)
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
    /// ceiling; the retry-once wrapper in `upload(filePath:folderId:isRetry:)`
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
        // missed-call screenshots (.png, see `ScreenCaptureService`) are
        // this upload path's second caller — no need for a fuller
        // extension→MIME lookup table beyond these two.
        if path.hasSuffix(".m4a") { return "audio/mp4" }
        if path.hasSuffix(".png") { return "image/png" }
        return "application/octet-stream"
    }
}
