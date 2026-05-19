import Foundation
import Combine

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    // MARK: - Onboarding
    @Published var isSetupComplete: Bool = false
    @Published var managerName: String = ""

    // MARK: - Telegram
    @Published var telegramApiId: Int32 = 0
    @Published var telegramApiHash: String = ""
    @Published var telegramChatId: Int64 = 0
    @Published var isTelegramAuthorized: Bool = false

    // MARK: - Google Drive
    @Published var googleDriveFolderId: String = ""
    @Published var isGoogleDriveEnabled: Bool = false

    // MARK: - Detection tuning
    @Published var monitoredBundleIDs: [String] = [
        "ru.keepcoder.Telegram",
        "org.telegram.desktop",
        "com.viber",
        "net.whatsapp.WhatsApp",
    ]
    @Published var callStartThresholdDB: Float = -40
    @Published var callStartConfirmSeconds: Double = 2.0
    @Published var callEndSilenceSeconds: Double = 3.0

    // MARK: - Persistence
    private let fileURL: URL
    private var cancellables = Set<AnyCancellable>()

    private init() {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Replixer", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("settings.json")
        load()
        setupAutoSave()
    }

    private struct Snapshot: Codable {
        var isSetupComplete: Bool
        var managerName: String
        var telegramApiId: Int32
        var telegramApiHash: String
        var telegramChatId: Int64
        var isTelegramAuthorized: Bool
        var googleDriveFolderId: String
        var isGoogleDriveEnabled: Bool
        var monitoredBundleIDs: [String]
        var callStartThresholdDB: Float
        var callStartConfirmSeconds: Double
        var callEndSilenceSeconds: Double
    }

    private func setupAutoSave() {
        let debouncedSave = PassthroughSubject<Void, Never>()
        debouncedSave
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] in self?.save() }
            .store(in: &cancellables)

        let trigger = { [weak self] in
            guard let self else { return }
            _ = self // suppress warning — just observe any change
            debouncedSave.send()
        }

        $isSetupComplete.dropFirst().sink { _ in trigger() }.store(in: &cancellables)
        $managerName.dropFirst().sink { _ in trigger() }.store(in: &cancellables)
        $telegramApiId.dropFirst().sink { _ in trigger() }.store(in: &cancellables)
        $telegramApiHash.dropFirst().sink { _ in trigger() }.store(in: &cancellables)
        $telegramChatId.dropFirst().sink { _ in trigger() }.store(in: &cancellables)
        $isTelegramAuthorized.dropFirst().sink { _ in trigger() }.store(in: &cancellables)
        $googleDriveFolderId.dropFirst().sink { _ in trigger() }.store(in: &cancellables)
        $isGoogleDriveEnabled.dropFirst().sink { _ in trigger() }.store(in: &cancellables)
        $callStartThresholdDB.dropFirst().sink { _ in trigger() }.store(in: &cancellables)
        $callStartConfirmSeconds.dropFirst().sink { _ in trigger() }.store(in: &cancellables)
        $callEndSilenceSeconds.dropFirst().sink { _ in trigger() }.store(in: &cancellables)
    }

    func save() {
        let snap = Snapshot(
            isSetupComplete: isSetupComplete,
            managerName: managerName,
            telegramApiId: telegramApiId,
            telegramApiHash: telegramApiHash,
            telegramChatId: telegramChatId,
            isTelegramAuthorized: isTelegramAuthorized,
            googleDriveFolderId: googleDriveFolderId,
            isGoogleDriveEnabled: isGoogleDriveEnabled,
            monitoredBundleIDs: monitoredBundleIDs,
            callStartThresholdDB: callStartThresholdDB,
            callStartConfirmSeconds: callStartConfirmSeconds,
            callEndSilenceSeconds: callEndSilenceSeconds
        )
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data)
        else { return }

        isSetupComplete = snap.isSetupComplete
        managerName = snap.managerName
        telegramApiId = snap.telegramApiId
        telegramApiHash = snap.telegramApiHash
        telegramChatId = snap.telegramChatId
        isTelegramAuthorized = snap.isTelegramAuthorized
        googleDriveFolderId = snap.googleDriveFolderId
        isGoogleDriveEnabled = snap.isGoogleDriveEnabled
        monitoredBundleIDs = snap.monitoredBundleIDs
        callStartThresholdDB = snap.callStartThresholdDB
        callStartConfirmSeconds = snap.callStartConfirmSeconds
        callEndSilenceSeconds = snap.callEndSilenceSeconds
    }

    // Convenience: TDLib files directory
    var tdlibDirectory: String {
        let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Replixer/tdlib", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.path
    }

    // Recordings output directory
    var recordingsDirectory: URL {
        let url = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Replixer/Recordings", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
