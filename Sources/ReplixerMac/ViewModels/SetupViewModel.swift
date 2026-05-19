import Foundation
import Combine

@MainActor
final class SetupViewModel: ObservableObject {

    enum Step: Int, CaseIterable {
        case manager    // 1 — manager name
        case telegram   // 2 — Telegram login
        case drive      // 3 — Google Drive folder
        case done       // 4 — finish

        var title: String {
            switch self {
            case .manager:  return "Ваш профіль"
            case .telegram: return "Telegram"
            case .drive:    return "Google Drive"
            case .done:     return "Готово"
            }
        }
    }

    @Published var currentStep: Step = .manager
    @Published var managerNameInput: String = ""
    @Published var telegramApiId: String = ""
    @Published var telegramApiHash: String = ""
    @Published var phoneInput: String = ""
    @Published var codeInput: String = ""
    @Published var passwordInput: String = ""
    @Published var folderId: String = ""
    @Published var driveTestResult: String?
    @Published var isTestingDrive = false
    @Published var canFinish = false

    private let settings: AppSettings
    let telegramAuth: TelegramAuthService
    let driveService: GoogleDriveService
    private var cancellables = Set<AnyCancellable>()

    var onSetupCompleted: (() -> Void)?

    init(settings: AppSettings, telegramAuth: TelegramAuthService, driveService: GoogleDriveService) {
        self.settings = settings
        self.telegramAuth = telegramAuth
        self.driveService = driveService
        managerNameInput = settings.managerName
        folderId = settings.googleDriveFolderId

        $managerNameInput
            .map { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .assign(to: &$canFinish)
    }

    // MARK: - Navigation

    func goNext() {
        guard let next = Step(rawValue: currentStep.rawValue + 1) else { return }
        currentStep = next
    }

    func goBack() {
        guard let prev = Step(rawValue: currentStep.rawValue - 1) else { return }
        currentStep = prev
    }

    var canProceedFromManager: Bool {
        !managerNameInput.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - Telegram

    func startTelegramAuth() {
        let id = Int32(telegramApiId) ?? 0
        settings.telegramApiId   = id
        settings.telegramApiHash = telegramApiHash
        telegramAuth.start()
    }

    func submitPhone() async {
        await telegramAuth.submitPhone(phoneInput)
    }

    func submitCode() async {
        await telegramAuth.submitCode(codeInput)
    }

    func submitPassword() async {
        await telegramAuth.submitPassword(passwordInput)
    }

    // MARK: - Google Drive

    func testDriveAccess() async {
        isTestingDrive = true
        driveTestResult = nil
        let result = await driveService.testFolderAccess(folderId: folderId)
        driveTestResult = result == nil ? "✓ Папку знайдено" : "✗ \(result!)"
        isTestingDrive = false
    }

    // MARK: - Finish

    func finish() {
        settings.managerName         = managerNameInput.trimmingCharacters(in: .whitespaces)
        settings.googleDriveFolderId = folderId
        settings.isGoogleDriveEnabled = !folderId.isEmpty
        settings.isTelegramAuthorized = telegramAuth.authState == .ready
        settings.isSetupComplete     = true
        settings.save()
        onSetupCompleted?()
    }
}
