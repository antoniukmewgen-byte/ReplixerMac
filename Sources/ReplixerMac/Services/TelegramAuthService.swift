import Foundation
import TDLibKit

@MainActor
final class TelegramAuthService: ObservableObject {

    enum AuthState: Equatable {
        case idle
        case waitingPhone
        case waitingCode(phoneNumber: String)
        case waitingPassword
        case ready
        case error(String)
    }

    @Published private(set) var authState: AuthState = .idle
    @Published private(set) var currentUserName: String = ""

    private var api: TdApi?
    private let manager = TDLibClientManager()
    private var pendingPhone: String = ""
    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: - Lifecycle

    func start() {
        guard api == nil else { return }

        // New TDLibKit API: callback-based, no async stream
        api = manager.createClient(
            updateHandler: { [weak self] update, _ in
                Task { @MainActor [weak self] in
                    await self?.handle(update: update)
                }
            },
            completionQueue: .global(qos: .userInitiated)
        )
    }

    func stop() {
        api = nil
    }

    // MARK: - Auth actions

    func submitPhone(_ phone: String) async {
        guard let api else { return }
        pendingPhone = phone
        do {
            try await api.setAuthenticationPhoneNumber(
                phoneNumber: phone,
                settings: .init(
                    allowFlashCall: false,
                    allowMissedCall: false,
                    allowSmsRetrieverApi: false,
                    authenticationTokens: [],
                    firebaseAuthenticationSettings: nil,
                    hasUnknownPhoneNumber: false,
                    isCurrentPhoneNumber: true
                )
            )
        } catch {
            authState = .error(error.localizedDescription)
        }
    }

    func submitCode(_ code: String) async {
        guard let api else { return }
        do { try await api.checkAuthenticationCode(code: code) }
        catch { authState = .error(error.localizedDescription) }
    }

    func submitPassword(_ password: String) async {
        guard let api else { return }
        do { try await api.checkAuthenticationPassword(password: password) }
        catch { authState = .error(error.localizedDescription) }
    }

    func logOut() async {
        guard let api else { return }
        try? await api.logOut()
        authState = .idle
        settings.isTelegramAuthorized = false
    }

    // MARK: - Update handler

    private func handle(update: Update) async {
        switch update {
        case .updateAuthorizationState(let u):
            await handleAuth(u.authorizationState)
        case .updateUser(let u):
            if let me = try? await api?.getMe(), u.user.id == me.id {
                currentUserName = [u.user.firstName, u.user.lastName]
                    .filter { !$0.isEmpty }.joined(separator: " ")
            }
        default:
            break
        }
    }

    private func handleAuth(_ state: AuthorizationState) async {
        switch state {
        case .authorizationStateWaitTdlibParameters:
            await configureTdlib()
        case .authorizationStateWaitPhoneNumber:
            authState = .waitingPhone
        case .authorizationStateWaitCode:
            authState = .waitingCode(phoneNumber: pendingPhone)
        case .authorizationStateWaitPassword:
            authState = .waitingPassword
        case .authorizationStateReady:
            authState = .ready
            settings.isTelegramAuthorized = true
            if let me = try? await api?.getMe() {
                currentUserName = [me.firstName, me.lastName]
                    .filter { !$0.isEmpty }.joined(separator: " ")
            }
        case .authorizationStateLoggingOut,
             .authorizationStateClosing,
             .authorizationStateClosed:
            authState = .idle
            settings.isTelegramAuthorized = false
        default:
            break
        }
    }

    private func configureTdlib() async {
        guard let api else { return }
        let dbDir = settings.tdlibDirectory
        do {
            try await api.setTdlibParameters(
                apiHash:               settings.telegramApiHash,
                apiId:                 Int(settings.telegramApiId),
                applicationVersion:    "1.0",
                databaseDirectory:     dbDir + "/db",
                databaseEncryptionKey: Data(),
                deviceModel:           "Mac",
                filesDirectory:        dbDir + "/files",
                systemLanguageCode:    Locale.current.identifier,
                systemVersion:         ProcessInfo.processInfo.operatingSystemVersionString,
                useChatInfoDatabase:   true,
                useFileDatabase:       true,
                useMessageDatabase:    true,
                useSecretChats:        false,
                useTestDc:             false
            )
        } catch {
            authState = .error("TDLib config failed: \(error.localizedDescription)")
        }
    }
}
