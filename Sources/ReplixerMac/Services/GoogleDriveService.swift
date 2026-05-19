import Foundation

// Google Drive upload via service-account JSON (same flow as the Windows version).
// Place service_account.json in the app bundle (Resources/) or load from disk.
final class GoogleDriveService: ObservableObject {

    @Published private(set) var isAuthorized = false

    private var accessToken: String?
    private var tokenExpiry: Date = .distantPast
    private let serviceAccountURL: URL?

    var onProgress:  ((Double) -> Void)?  // 0…1
    var onCompleted: ((String) -> Void)?  // webViewLink
    var onFailed:    ((String) -> Void)?

    init() {
        // Look for service_account.json next to the binary first, then in Resources
        let bundleURL = Bundle.main.url(forResource: "service_account", withExtension: "json")
        let siblingURL = Bundle.main.bundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("service_account.json")
        serviceAccountURL = bundleURL ?? (FileManager.default.fileExists(atPath: siblingURL.path) ? siblingURL : nil)
        isAuthorized = serviceAccountURL != nil
    }

    // MARK: - Public

    func testFolderAccess(folderId: String) async -> String? {
        guard let token = try? await freshToken() else {
            return "Не вдалося отримати токен доступу — перевірте service_account.json"
        }
        guard !folderId.isEmpty else { return "ID папки не вказано" }

        var req = URLRequest(url: driveFileURL(folderId: folderId))
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            if status == 200 { return nil }
            let body = String(data: data, encoding: .utf8) ?? ""
            return "HTTP \(status): \(body)"
        } catch {
            return error.localizedDescription
        }
    }

    func upload(fileURL: URL, folderId: String?) async -> String? {
        guard let token = try? await freshToken() else {
            onFailed?("Не вдалося отримати токен доступу")
            return nil
        }

        // Step 1: initiate resumable upload
        guard let uploadURI = await initiateResumableUpload(
            token: token,
            fileName: fileURL.lastPathComponent,
            folderId: folderId
        ) else {
            onFailed?("Не вдалося ініціювати завантаження")
            return nil
        }

        // Step 2: upload file body
        guard let data = try? Data(contentsOf: fileURL) else {
            onFailed?("Не вдалося прочитати файл: \(fileURL.lastPathComponent)")
            return nil
        }

        return await uploadData(data, to: uploadURI, token: token, fileName: fileURL.lastPathComponent)
    }

    func getOrCreateUserFolder(parentId: String, userName: String) async -> String? {
        guard let token = try? await freshToken() else { return nil }

        // Search existing
        let escaped = userName.replacingOccurrences(of: "'", with: "\\'")
        let q = "name='\(escaped)' and mimeType='application/vnd.google-apps.folder' and '\(parentId)' in parents and trashed=false"
        var components = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        components.queryItems = [
            URLQueryItem(name: "q", value: q),
            URLQueryItem(name: "fields", value: "files(id,name)"),
            URLQueryItem(name: "supportsAllDrives", value: "true"),
            URLQueryItem(name: "includeItemsFromAllDrives", value: "true"),
        ]

        var listReq = URLRequest(url: components.url!)
        listReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        if let (data, _) = try? await URLSession.shared.data(for: listReq),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let files = json["files"] as? [[String: Any]],
           let first = files.first,
           let id = first["id"] as? String {
            return id
        }

        // Create
        let body: [String: Any] = [
            "name": userName,
            "mimeType": "application/vnd.google-apps.folder",
            "parents": [parentId],
        ]
        var createReq = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files?supportsAllDrives=true&fields=id")!)
        createReq.httpMethod = "POST"
        createReq.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        createReq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        createReq.httpBody = try? JSONSerialization.data(withJSONObject: body)

        if let (data, _) = try? await URLSession.shared.data(for: createReq),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = json["id"] as? String {
            return id
        }

        return nil
    }

    // MARK: - OAuth2 / Service account

    private func freshToken() async throws -> String {
        if let token = accessToken, Date() < tokenExpiry { return token }
        let token = try await fetchServiceAccountToken()
        accessToken = token
        tokenExpiry = Date().addingTimeInterval(3500)
        return token
    }

    private func fetchServiceAccountToken() async throws -> String {
        guard let saURL = serviceAccountURL,
              let saData = try? Data(contentsOf: saURL),
              let sa = try? JSONDecoder().decode(ServiceAccount.self, from: saData)
        else { throw GoogleDriveError.missingServiceAccount }

        let now = Int(Date().timeIntervalSince1970)
        let payload: [String: Any] = [
            "iss": sa.clientEmail,
            "scope": "https://www.googleapis.com/auth/drive",
            "aud": "https://oauth2.googleapis.com/token",
            "iat": now,
            "exp": now + 3600,
        ]

        let jwt = try buildJWT(header: ["alg": "RS256", "typ": "JWT"],
                               payload: payload,
                               privateKeyPEM: sa.privateKey)

        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=\(jwt)"
            .data(using: .utf8)

        let (data, _) = try await URLSession.shared.data(for: req)
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let token = json["access_token"] as? String
        else { throw GoogleDriveError.tokenFetchFailed }

        return token
    }

    // MARK: - Resumable upload

    private func initiateResumableUpload(token: String, fileName: String, folderId: String?) async -> URL? {
        var metadata: [String: Any] = ["name": fileName, "mimeType": "audio/m4a"]
        if let fid = folderId, !fid.isEmpty { metadata["parents"] = [fid] }

        var req = URLRequest(url: URL(string: "https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable&supportsAllDrives=true")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: metadata)

        guard let (_, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse,
              let location = http.value(forHTTPHeaderField: "Location"),
              let locationURL = URL(string: location)
        else { return nil }

        return locationURL
    }

    private func uploadData(_ data: Data, to uri: URL, token: String, fileName: String) async -> String? {
        var req = URLRequest(url: uri)
        req.httpMethod = "PUT"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("audio/m4a", forHTTPHeaderField: "Content-Type")
        req.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        req.httpBody = data

        // Track progress via delegate
        let delegate = UploadDelegate(totalBytes: Int64(data.count), onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)

        do {
            let (respData, response) = try await session.data(for: req)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard status == 200 || status == 201 else {
                let body = String(data: respData, encoding: .utf8) ?? ""
                onFailed?("HTTP \(status): \(body)")
                return nil
            }
            if let json = try? JSONSerialization.jsonObject(with: respData) as? [String: Any],
               let link = json["webViewLink"] as? String {
                onCompleted?(link)
                return link
            }
            onCompleted?("")
            return ""
        } catch {
            onFailed?(error.localizedDescription)
            return nil
        }
    }

    private func driveFileURL(folderId: String) -> URL {
        URL(string: "https://www.googleapis.com/drive/v3/files/\(folderId)?fields=id,name,mimeType&supportsAllDrives=true")!
    }

    // MARK: - JWT (RS256)

    private func buildJWT(header: [String: Any], payload: [String: Any], privateKeyPEM: String) throws -> String {
        func base64url(_ data: Data) -> String {
            data.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }

        let headerData  = try JSONSerialization.data(withJSONObject: header)
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let signingInput = "\(base64url(headerData)).\(base64url(payloadData))"

        let key = try loadRSAPrivateKey(pem: privateKeyPEM)
        var error: Unmanaged<CFError>?
        guard
            let inputData = signingInput.data(using: .utf8),
            let signature = SecKeyCreateSignature(key, .rsaSignatureMessagePKCS1v15SHA256, inputData as CFData, &error) as Data?
        else { throw error?.takeRetainedValue() ?? GoogleDriveError.jwtSignFailed }

        return "\(signingInput).\(base64url(signature))"
    }

    private func loadRSAPrivateKey(pem: String) throws -> SecKey {
        let stripped = pem
            .replacingOccurrences(of: "-----BEGIN RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----BEGIN PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END RSA PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "-----END PRIVATE KEY-----", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespaces)

        guard let keyData = Data(base64Encoded: stripped) else {
            throw GoogleDriveError.invalidPEM
        }

        let attrs: [String: Any] = [
            kSecAttrKeyType as String:       kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String:      kSecAttrKeyClassPrivate,
            kSecAttrKeySizeInBits as String: 2048,
        ]
        var cfError: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(keyData as CFData, attrs as CFDictionary, &cfError) else {
            throw cfError?.takeRetainedValue() ?? GoogleDriveError.keyLoadFailed
        }
        return key
    }

    // MARK: - Types

    private struct ServiceAccount: Decodable {
        let clientEmail: String
        let privateKey: String
        enum CodingKeys: String, CodingKey {
            case clientEmail = "client_email"
            case privateKey  = "private_key"
        }
    }

    enum GoogleDriveError: Error {
        case missingServiceAccount
        case tokenFetchFailed
        case jwtSignFailed
        case invalidPEM
        case keyLoadFailed
    }
}

// MARK: - Upload progress delegate
private final class UploadDelegate: NSObject, URLSessionTaskDelegate {
    private let totalBytes: Int64
    private let onProgress: ((Double) -> Void)?

    init(totalBytes: Int64, onProgress: ((Double) -> Void)?) {
        self.totalBytes = totalBytes
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, task: URLSessionTask,
                    didSendBodyData bytesSent: Int64, totalBytesSent: Int64,
                    totalBytesExpectedToSend: Int64) {
        let progress = totalBytes > 0 ? Double(totalBytesSent) / Double(totalBytes) : 0
        onProgress?(min(progress, 1.0))
    }
}
