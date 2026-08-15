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
public final class TelegramAuthClient {
    // Explicit public init required: a public type with no explicit
    // initializer only gets an internal-access default/memberwise init
    // synthesized, which main.swift (a different target) can't call.
    public init() {}

    /// Phase 7.8: UI-drivable replacement for the blocking `readLine()` path
    /// below — Windows parity: `TelegramUploadService.InputHandler`
    /// (`Func<string, Task<string?>>?`). Unlike Windows, which has to bounce
    /// the request onto a dedicated thread with its own `SynchronizationContext`
    /// pump (WTelegram's login call blocks synchronously waiting for the
    /// answer), Swift's native `async`/`await` already suspends
    /// `advance(authorizationState:...)` without blocking anything — the
    /// `Task` `route(data:client:...)` spawns per update is free to just
    /// `await` this closure directly. `isSecure` lets the caller mask a 2FA
    /// password (`SecureField`) while leaving the SMS verification code
    /// visible — a small improvement over Windows' single generic
    /// `InputDialogViewModel`, which doesn't distinguish the two. Returning
    /// `nil` signals the user cancelled the prompt (`TelegramAuthError
    /// .cancelled`), mirroring `InputDialogViewModel.CancelCommand`.
    public typealias TelegramAuthInputHandler = @Sendable (_ prompt: String, _ isSecure: Bool) async -> String?

    private let manager = TDLibClientManager()
    // Set once per `login(phone:inputHandler:)` call, read from
    // `advance(authorizationState:...)` below — `presetPhone` lets an
    // interactive authorize skip the phone prompt entirely (the caller
    // already has it from a text field), `inputHandler` (nil for the
    // no-argument silent-resume overload `CallRecordingCoordinator` uses)
    // is what routes the code/2FA prompts to UI instead of stdin.
    private var presetPhone: String?
    private var inputHandler: TelegramAuthInputHandler?
    // Phase 4.2: private(set), not private — the chat-listing/send-message
    // diagnostics need to reuse this same authenticated TDLibClient rather
    // than spinning up (and re-authenticating) a fresh TelegramAuthClient
    // per operation.
    private(set) var client: TDLibClient!
    // Explicitly Swift.Error, not TDLibKit's own `Error` model struct (its
    // representation of a TDLib error) — `import TDLibKit` shadows the
    // bare `Error` name in this file, so every use of the throwing-error
    // protocol here has to be qualified or it silently resolves to the
    // wrong type and fails to compile.
    private var readyContinuation: CheckedContinuation<Void, Swift.Error>?
    // Phase 4.2: TDLib pushes this once, shortly after authorization, as an
    // `updateChatFolders` update — there is no request/response RPC to pull
    // it on demand, so it has to be captured here as it flies by and cached
    // for diagnostics (TelegramChatListSmokeTest) that need to enumerate
    // chats living inside a folder (`.chatListFolder`), not just the main
    // list.
    private(set) var chatFolders: [ChatFolderInfo] = []

    // Phase 6 fix: `sendMessage`'s immediate return value carries a
    // *temporary* local message id — TDLib's own doc comment on
    // `updateMessageSendSucceeded.oldMessageId` calls it out explicitly as
    // "the previous temporary message identifier". That temporary id stops
    // being valid for follow-up operations (e.g. `editMessageCaption`, used
    // by `TelegramUploadService.editCaption` for the Phase 6 Drive-link
    // caption patch) once the server actually confirms the send and swaps
    // in the real id — trying to use the temporary id later fails with
    // `MESSAGE_CANT_BE_EDITED` regardless of how long you wait, since it's
    // simply the wrong id, not a timing race. Correlates temp id -> real id
    // by listening for `updateMessageSendSucceeded`/`updateMessageSendFailed`
    // in `route(data:client:apiId:apiHash:)` below, so callers can await the
    // real id instead of trusting `sendMessage`'s return value directly.
    private var pendingSendResolutions: [Int64: CheckedContinuation<Int64, Never>] = [:]

    // static, not instance — it depends on nothing instance-specific, and
    // Phase 7.6's `hasSavedSession` needs to read it without spinning up a
    // full `TelegramAuthClient` (constructing one starts pulling in
    // `TDLibClientManager` machinery this check has no reason to touch).
    private static let databaseDirectory: URL = {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReplixerMac", isDirectory: true)
            .appendingPathComponent("TDLib", isDirectory: true)
    }()

    /// Non-interactive, instant, filesystem-only check for whether a TDLib
    /// session database already exists on disk — Phase 7.6's Profile screen
    /// uses this to show a safe "сесія збережена" indicator instead of a
    /// "Перевірити з'єднання" button wired to `login()`. `login()` resumes
    /// silently when a session is already saved, but prompts (blocking on
    /// `readLine()`, see that method's and `promptLine`'s doc comments) when
    /// it isn't — a real risk for a button in a double-clicked `.app` with
    /// no console attached. This can't tell whether a saved session is still
    /// *valid* (Telegram could have revoked it server-side), only whether
    /// the on-disk signal `login()` itself relies on is present; it's a
    /// best-effort status readout, not a connection test.
    public static var hasSavedSession: Bool {
        let contents = try? FileManager.default.contentsOfDirectory(atPath: databaseDirectory.path)
        return !(contents?.isEmpty ?? true)
    }

    /// Deletes the on-disk TDLib session database, forcing the next
    /// `login()` call to start a fresh interactive authorization instead of
    /// resuming. Static + filesystem-only, same shape as `hasSavedSession`
    /// above — mirrors Windows' `TelegramUploadService.Logout()` (session-
    /// file delete), but without also needing to reach into any live
    /// in-memory client: every interactive authorize flow
    /// (`TelegramAuthSection`, shared by `ProfileView`/`SetupWizardView`)
    /// constructs a throwaway `TelegramAuthClient()` instance per attempt
    /// rather than keeping one around, so there's nothing else here that
    /// needs tearing down. Safe to call even if no session exists yet.
    public static func logout() {
        try? FileManager.default.removeItem(at: databaseDirectory)
    }

    /// Starts the login flow (or, if a session already exists on disk,
    /// resumes it silently) and suspends until `authorizationStateReady` is
    /// reached. Throws `TelegramAuthError.missingCredentials` if
    /// `AppSecrets.telegramApiId`/`telegramApiHash` haven't been baked into
    /// this build (`AppSecrets.example.swift`'s placeholder `0`/`""` — see
    /// its doc comment), same "build-time constant, not a per-user setting"
    /// treatment as `AppSecrets.googleServiceAccountJson`. Otherwise
    /// rethrows whatever TDLib call failed along the way.
    ///
    /// - Parameters:
    ///   - phone: When non-nil, this is an explicit interactive authorize
    ///     (Phase 7.8: `TelegramAuthSection`'s "Авторизувати" button) —
    ///     answers `authorizationStateWaitPhoneNumber` with this value
    ///     directly (no prompt needed) and, Windows-parity
    ///     (`AuthorizeAsync` "завжди починаємо з чистого файлу сесії"),
    ///     wipes any existing session first via `logout()` so a user
    ///     switching accounts never gets stuck on stale TDLib state. `nil`
    ///     (the default) preserves the original silent-resume-only
    ///     behavior `CallRecordingCoordinator.telegramClient()` depends on.
    ///   - inputHandler: Routes `authorizationStateWaitCode`/
    ///     `authorizationStateWaitPassword` prompts to UI instead of
    ///     blocking stdin. `nil` (the default) preserves the original
    ///     `readLine()`-based behavior the CLI smoke tests and the headless
    ///     `CallRecordingCoordinator` resume path rely on (which should
    ///     never actually hit a prompt in practice — resuming from a saved
    ///     session goes straight to `authorizationStateReady`).
    public func login(phone: String? = nil, inputHandler: TelegramAuthInputHandler? = nil) async throws {
        let apiId = AppSecrets.telegramApiId
        let apiHash = AppSecrets.telegramApiHash
        guard apiId != 0, !apiHash.isEmpty else {
            throw TelegramAuthError.missingCredentials
        }

        if phone != nil {
            Self.logout()
        }

        try FileManager.default.createDirectory(at: Self.databaseDirectory, withIntermediateDirectories: true)

        self.presetPhone = phone
        self.inputHandler = inputHandler

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
    /// `TDLibClientManager`) — recognizes authorization-state updates (Phase
    /// 4.1) and chat-folders updates (Phase 4.2, see `chatFolders` above),
    /// ignores everything else (messages, chat updates, etc. — none of that
    /// exists yet). Authorization handling is dispatched into a `Task` so
    /// the (possibly stdin-blocking) work in
    /// `advance(authorizationState:...)` doesn't block this queue from
    /// delivering the *next* update once we reply.
    private func route(data: Data, client: TDLibClient, apiId: Int, apiHash: String) {
        guard let update = try? client.decoder.decode(Update.self, from: data) else { return }

        switch update {
        case .updateAuthorizationState(let stateUpdate):
            Task {
                do {
                    try await advance(authorizationState: stateUpdate.authorizationState, client: client, apiId: apiId, apiHash: apiHash)
                } catch {
                    print("[TelegramAuthClient] ❌ помилка авторизації: \(error)")
                    readyContinuation?.resume(throwing: error)
                    readyContinuation = nil
                }
            }

        case .updateChatFolders(let foldersUpdate):
            chatFolders = foldersUpdate.chatFolders

        case .updateMessageSendSucceeded(let succeeded):
            if let continuation = pendingSendResolutions.removeValue(forKey: succeeded.oldMessageId) {
                continuation.resume(returning: succeeded.message.id)
            }

        case .updateMessageSendFailed(let failed):
            // Send ultimately failed server-side after all (rare — the
            // in-process catch in TelegramUploadService.sendRecording
            // normally sees this first via the RPC's own thrown error).
            // Resolve with the temporary id itself just to unblock the
            // awaiting continuation rather than hanging forever; nothing
            // downstream will find that id valid, but the caller's own
            // error handling already treats the send as failed through a
            // different path, so this is purely a safety net against a
            // stuck await.
            if let continuation = pendingSendResolutions.removeValue(forKey: failed.oldMessageId) {
                continuation.resume(returning: failed.oldMessageId)
            }

        default:
            // Messages, chat updates, etc. — nothing for the login flow
            // itself to react to (Phase 4.1/4.2 scope).
            break
        }
    }

    private func advance(authorizationState: AuthorizationState, client: TDLibClient, apiId: Int, apiHash: String) async throws {
        switch authorizationState {
        case .authorizationStateWaitTdlibParameters:
            try await client.setTdlibParameters(
                apiHash: apiHash,
                apiId: apiId,
                applicationVersion: "1.0",
                databaseDirectory: Self.databaseDirectory.path,
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
            let phone: String
            if let presetPhone, !presetPhone.isEmpty {
                phone = presetPhone
            } else if let inputHandler {
                guard let answer = await inputHandler("Введіть номер телефону (у міжнародному форматі, напр. +380...):", false) else {
                    throw TelegramAuthError.cancelled
                }
                phone = answer
            } else {
                phone = Self.promptLine("[TelegramAuthClient] Введи номер телефону (у міжнародному форматі, напр. +380...): ")
            }
            try await client.setAuthenticationPhoneNumber(phoneNumber: phone, settings: nil)

        case .authorizationStateWaitCode:
            let code: String
            if let inputHandler {
                guard let answer = await inputHandler("Введіть код підтвердження з Telegram:", false) else {
                    throw TelegramAuthError.cancelled
                }
                code = answer
            } else {
                code = Self.promptLine("[TelegramAuthClient] Введи код підтвердження з Telegram: ")
            }
            try await client.checkAuthenticationCode(code: code)

        case .authorizationStateWaitPassword:
            let password: String
            if let inputHandler {
                guard let answer = await inputHandler("Введіть пароль двоетапної перевірки (2FA):", true) else {
                    throw TelegramAuthError.cancelled
                }
                password = answer
            } else {
                password = Self.promptLine("[TelegramAuthClient] Введи пароль двоетапної перевірки (2FA): ")
            }
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

    /// Suspends until TDLib confirms the send that produced `temporaryId`
    /// (`sendMessage`'s own immediate return value) and resolves with the
    /// real, server-confirmed message id — see the `pendingSendResolutions`
    /// doc comment above for why the temporary id can't be used directly
    /// for later operations like `editMessageCaption`.
    func finalMessageId(forTemporaryId temporaryId: Int64) async -> Int64 {
        await withCheckedContinuation { continuation in
            pendingSendResolutions[temporaryId] = continuation
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
    public func shutdown() {
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

public enum TelegramAuthError: Swift.Error {
    case missingCredentials
    case registrationNotSupported
    case closedBeforeReady
    /// The user dismissed an interactive code/2FA/phone prompt without
    /// answering — `inputHandler` returned `nil`. Windows parity:
    /// `InputDialogViewModel.CancelCommand` calling `onComplete(null)`.
    case cancelled
}
