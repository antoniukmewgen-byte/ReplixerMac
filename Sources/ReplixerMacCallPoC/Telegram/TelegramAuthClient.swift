import Foundation
import TDLibKit

/// Phase 4.1: minimal interactive TDLib login (phone + code + optional 2FA
/// password), driven from stdin — same CLI-smoke-test style established in
/// Phase 1-3 (no UI until Phase 7). Purpose is to verify the login
/// handshake actually works end to end on a real Mac, and that TDLib's own
/// on-disk session database persists across restarts (a second run should
/// reach `authorizationStateReady` silently, without re-prompting for
/// phone/code).
///
/// One `TDLibClientManager` per app process (its docs: `td_receive` can
/// only be called from a single thread — the manager owns that thread
/// internally) — this class owns that single manager and the one
/// `TDLibClient` built from it, since Phase 4 only ever needs one Telegram
/// session at a time.
final class TelegramAuthClient {
    private let manager = TDLibClientManager()
    private var client: TDLibClient!
    // Explicitly Swift.Error, not TDLibKit's own `Error` model struct (its
    // representation of a TDLib API error) — `import TDLibKit` shadows the
    // bare `Error` name in this file, so every use of the throwing-error
    // protocol here has to be qualified or it silently resolves to the
    // wrong type and fails to compile.
    private var readyContinuation: CheckedContinuation<Void, Swift.Error>?

    private let databaseDirectory: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReplixerMac", isDirectory: true)
            .appendingPathComponent("TDLib", isDirectory: true)
    }()

    /// Starts the login flow (or, if a session already exists on disk,
    /// resumes it silently) and suspends until `authorizationStateReady` is
    /// reached. Throws `TelegramAuthError.missingCredentials` if
    /// `AppSettings` doesn't have both `telegramApiId`/`telegramApiHash`
    /// set yet (no UI for these until Phase 7 — see AppSettings.swift), or
    /// rethrows whatever TDLib call failed along the way.
    func login() async throws {
        guard let apiId = AppSettings.shared.telegramApiId,
              let apiHash = AppSettings.shared.telegramApiHash else {
            throw TelegramAuthError.missingCredentials
        }

        try FileManager.default.createDirectory(at: databaseDirectory, withIntermediateDirectories: true)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Swift.Error>) in
            self.readyContinuation = continuation
            let newClient = manager.createClient { [weak self] data, client in
                self?.route(data: data, client: client, apiId: apiId, apiHash: apiHash)
            }
            self.client = newClient

            // TDLib's default log verbosity (5, "verbose") floods stdout
            // with internal Client.cpp/ConfigManager.cpp trace lines fast
            // enough to bury the phone-number/code prompts this CLI flow
            // depends on being visible — dial it down to "errors only"
            // immediately. Fire-and-forget: if this particular call fails,
            // worst case is a noisy terminal, not a broken login.
            Task { try? await newClient.setLogVerbosityLevel(newVerbosityLevel: 1) }
        }
    }

    /// Runs on the client's own serial update-handler queue (per
    /// `TDLibClientManager`) — decodes just enough to recognize
    /// authorization-state updates and ignores everything else (messages,
    /// chat updates, etc. — none of that exists yet in Phase 4.1). Actual
    /// handling is dispatched into a `Task` so the (possibly
    /// stdin-blocking) work in `advance(authorizationState:...)` doesn't
    /// block this queue from delivering the *next* update once we reply.
    private func route(data: Data, client: TDLibClient, apiId: Int, apiHash: String) {
        guard let update = try? client.decoder.decode(Update.self, from: data),
              case .updateAuthorizationState(let stateUpdate) = update else { return }

        Task {
            do {
                try await advance(authorizationState: stateUpdate.authorizationState, client: client, apiId: apiId, apiHash: apiHash)
            } catch {
                print("[TelegramAuthClient] ❌ помилка авторизації: \(error)")
                readyContinuation?.resume(throwing: error)
                readyContinuation = nil
            }
        }
    }

    private func advance(authorizationState: AuthorizationState, client: TDLibClient, apiId: Int, apiHash: String) async throws {
        switch authorizationState {
        case .authorizationStateWaitTdlibParameters:
            try await client.setTdlibParameters(
                apiHash: apiHash,
                apiId: apiId,
                applicationVersion: "1.0",
                databaseDirectory: databaseDirectory.path,
                databaseEncryptionKey: TelegramKeychain.databaseEncryptionKey(),
                deviceModel: "Mac",
                filesDirectory: nil,
                systemLanguageCode: "uk",
                systemVersion: nil,
                useChatInfoDatabase: true,
                useFileDatabase: true,
                useMessageDatabase: true,
                useSecretChats: false,
                useTestDc: false
            )

        case .authorizationStateWaitPhoneNumber:
            let phone = Self.promptLine("[TelegramAuthClient] Введи номер телефону (у міжнародному форматі, напр. +380...): ")
            try await client.setAuthenticationPhoneNumber(phoneNumber: phone, settings: nil)

        case .authorizationStateWaitCode:
            let code = Self.promptLine("[TelegramAuthClient] Введи код підтвердження з Telegram: ")
            try await client.checkAuthenticationCode(code: code)

        case .authorizationStateWaitPassword:
            let password = Self.promptLine("[TelegramAuthClient] Введи пароль двоетапної перевірки (2FA): ")
            try await client.checkAuthenticationPassword(password: password)

        case .authorizationStateWaitRegistration:
            // Existing-account login only, per Phase 4 scope — reaching
            // this state means the phone number typed above has no
            // Telegram account yet. Signing up a brand-new account isn't
            // something this PoC supports.
            print("[TelegramAuthClient] ❌ цей номер не зареєстрований у Telegram — реєстрація нового акаунту тут не підтримується.")
            throw TelegramAuthError.registrationNotSupported

        case .authorizationStateReady:
            print("[TelegramAuthClient] ✅ авторизація успішна.")
            readyContinuation?.resume(returning: ())
            readyContinuation = nil

        case .authorizationStateClosed:
            readyContinuation?.resume(throwing: TelegramAuthError.closedBeforeReady)
            readyContinuation = nil

        default:
            // authorizationStateLoggingOut/Closing, and any other
            // in-between state TDLib may report — nothing for the login
            // flow itself to react to.
            break
        }
    }

    /// Cleanly closes the TDLib client before the process exits. Calling
    /// `exit()` directly (as main.swift's smoke test does once `login()`
    /// returns) while TDLib's background `td_receive` thread is still
    /// running crashes with SIGSEGV — the manager's own docs call this out
    /// explicitly and recommend `closeClients()` first, which blocks until
    /// TDLib confirms `authorizationStateClosed` for every client, so the
    /// background thread has actually wound down before we pull the rug
    /// out with `exit()`.
    func shutdown() {
        manager.closeClients()
    }

    /// Blocking stdin read. Safe to call from inside the `Task` spawned in
    /// `route(data:client:...)` above (not from the update-handler queue
    /// itself) — same CLI-input pattern main.swift already uses for its
    /// 'q'-to-shut-down testing aid.
    private static func promptLine(_ prompt: String) -> String {
        print(prompt, terminator: "")
        return readLine() ?? ""
    }
}

enum TelegramAuthError: Swift.Error {
    case missingCredentials
    case registrationNotSupported
    case closedBeforeReady
}
