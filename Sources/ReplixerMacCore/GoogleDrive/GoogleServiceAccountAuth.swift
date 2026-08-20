import Foundation
import Security

/// Phase 5.1: Google service-account authentication — the macOS/Swift
/// counterpart to Windows' `GoogleCredential.FromStream(...).CreateScoped(...)`
/// (a mature client library that hides all of this). No comparably mature
/// Google API Swift client exists for macOS server-side/service-account
/// flows (plan's known risk #5), so this hand-rolls the JWT Bearer Token
/// flow (RFC 7523) directly:
///   1. Parse the service-account JSON for `client_email` + `private_key`.
///   2. Build a JWT (header + claims) and sign it RS256 via the Security
///      framework — CryptoKit has no RSA support at all (only
///      Curve25519/P-256/384/521, ChaChaPoly, AES-GCM, hashing, HMAC).
///   3. Exchange the signed JWT for a short-lived OAuth access token at
///      Google's token endpoint.
///
/// Credentials come from `AppSecrets.googleServiceAccountJson` — a
/// build-time-baked JSON string constant, not a file the user picks at
/// runtime. This is a deliberate switch to match Windows' model exactly
/// (`AppSecrets.GoogleServiceAccountJson`, populated from a
/// `GOOGLE_CREDENTIALS_JSON` CI secret): the service account is shared
/// across every user of a given build, not something each manager brings
/// their own copy of, so there's nothing for a per-user file picker to
/// usefully do. See `AppSecrets.example.swift` for the git-ignored-file
/// convention this reads from.
enum GoogleServiceAccountAuth {
    enum AuthError: Swift.Error {
        /// `AppSecrets.googleServiceAccountJson` is empty — the build
        /// wasn't given a real service account (e.g. a local dev build
        /// that never filled in `AppSecrets.swift`).
        case missingSecret
        case invalidServiceAccountJSON
        case invalidPrivateKeyPEM
        case signingFailed(String)
        case tokenRequestFailed(String)
    }

    private struct ServiceAccount: Decodable {
        let clientEmail: String
        let privateKey: String

        enum CodingKeys: String, CodingKey {
            case clientEmail = "client_email"
            case privateKey = "private_key"
        }
    }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Int

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case expiresIn = "expires_in"
        }
    }

    // Phase 15 (Google Sheets): the scope used to be hardcoded to Drive
    // (`.../auth/drive`) — GoogleSheetsUploadService needs a token scoped to
    // `.../auth/spreadsheets` instead, same service account, different
    // OAuth scope claim. Default keeps every existing call site (Drive)
    // compiling unchanged.
    static let driveScope = "https://www.googleapis.com/auth/drive"
    static let sheetsScope = "https://www.googleapis.com/auth/spreadsheets"

    /// Reads `AppSecrets.googleServiceAccountJson`, builds+signs a JWT, and
    /// exchanges it for an OAuth access token good for API calls under
    /// `scope` (defaults to Drive, matching Windows'
    /// `DriveService.Scope.Drive`; pass `sheetsScope` for Sheets calls).
    /// Returns the raw bearer token string — no expiry-tracking/reuse yet,
    /// each call just fetches a fresh one; revisit with caching in Step 5.2
    /// if repeated calls in quick succession turn out to matter.
    static func fetchAccessToken(scope: String = driveScope) async throws -> String {
        let json = AppSecrets.googleServiceAccountJson
        guard !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let data = json.data(using: .utf8) else {
            throw AuthError.missingSecret
        }
        let account: ServiceAccount
        do {
            account = try JSONDecoder().decode(ServiceAccount.self, from: data)
        } catch {
            throw AuthError.invalidServiceAccountJSON
        }

        let jwt = try signedJWT(clientEmail: account.clientEmail, privateKeyPEM: account.privateKey, scope: scope)
        return try await exchangeForAccessToken(jwt: jwt)
    }

    // MARK: - JWT construction

    private static func signedJWT(clientEmail: String, privateKeyPEM: String, scope: String) throws -> String {
        let now = Int(Date().timeIntervalSince1970)
        let header: [String: Any] = ["alg": "RS256", "typ": "JWT"]
        let claims: [String: Any] = [
            "iss": clientEmail,
            "scope": scope,
            "aud": "https://oauth2.googleapis.com/token",
            "exp": now + 3600,
            "iat": now
        ]

        let headerB64 = try base64URLEncode(json: header)
        let claimsB64 = try base64URLEncode(json: claims)
        let signingInput = "\(headerB64).\(claimsB64)"

        let signature = try sign(message: signingInput, privateKeyPEM: privateKeyPEM)
        let signatureB64 = base64URLEncode(data: signature)

        return "\(signingInput).\(signatureB64)"
    }

    private static func base64URLEncode(json: [String: Any]) throws -> String {
        // .sortedKeys purely for deterministic/debuggable output — JWT
        // parsers don't care about key order, this isn't a correctness
        // requirement.
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        return base64URLEncode(data: data)
    }

    private static func base64URLEncode(data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: - RSA signing (Security framework)

    private static func sign(message: String, privateKeyPEM: String) throws -> Data {
        let secKey = try importPrivateKey(pem: privateKeyPEM)
        guard let messageData = message.data(using: .utf8) else {
            throw AuthError.signingFailed("не вдалося закодувати JWT signing input у UTF-8.")
        }
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
            secKey,
            .rsaSignatureMessagePKCS1v15SHA256,
            messageData as CFData,
            &error
        ) as Data? else {
            let description = (error?.takeRetainedValue() as Error?)?.localizedDescription ?? "невідома помилка SecKeyCreateSignature."
            throw AuthError.signingFailed(description)
        }
        return signature
    }

    /// Google's service-account JSON ships the private key as PKCS#8 PEM
    /// (`-----BEGIN PRIVATE KEY-----`), but `SecKeyCreateWithData` with
    /// `kSecAttrKeyTypeRSA`/`kSecAttrKeyClassPrivate` expects raw PKCS#1
    /// `RSAPrivateKey` DER bytes — so the PKCS#8 wrapper has to be stripped
    /// first via `DERReader.pkcs1RSAKey(fromPKCS8:)`.
    private static func importPrivateKey(pem: String) throws -> SecKey {
        guard let der = Self.derBytes(fromPEM: pem) else {
            throw AuthError.invalidPrivateKeyPEM
        }
        guard let pkcs1 = DERReader.pkcs1RSAKey(fromPKCS8: der) else {
            throw AuthError.invalidPrivateKeyPEM
        }

        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate
        ]
        var error: Unmanaged<CFError>?
        guard let secKey = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error) else {
            let description = (error?.takeRetainedValue() as Error?)?.localizedDescription ?? "невідома помилка SecKeyCreateWithData."
            throw AuthError.signingFailed(description)
        }
        return secKey
    }

    private static func derBytes(fromPEM pem: String) -> Data? {
        let base64 = pem
            .split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        return Data(base64Encoded: base64)
    }

    // MARK: - Token exchange

    private static func exchangeForAccessToken(jwt: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let body = "grant_type=urn:ietf:params:oauth:grant-type:jwt-bearer&assertion=\(jwt)"
        request.httpBody = body.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "<нечитабельна відповідь>"
            throw AuthError.tokenRequestFailed(bodyText)
        }
        let decoded = try JSONDecoder().decode(TokenResponse.self, from: data)
        return decoded.accessToken
    }
}
