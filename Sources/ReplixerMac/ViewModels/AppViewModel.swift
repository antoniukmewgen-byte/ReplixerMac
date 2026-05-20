import Foundation
import Combine
import SwiftUI

// Central coordinator — owns all services and drives the UI state machine.
@MainActor
final class AppViewModel: ObservableObject {

    // MARK: - Published UI state
    @Published var recordings: [Recording] = []
    @Published var activeSession: CallSession?
    @Published var recordingDuration: TimeInterval = 0
    @Published var appError: String?
    @Published var uploadProgress: [UUID: Double] = [:]  // recordingId → 0…1

    // Services (injected via init for testability)
    let settings: AppSettings
    let audioTap: AudioTapService
    let recorder: RecordingService
    let driveService: GoogleDriveService
    let telegramAuth: TelegramAuthService
    let telegramUpload: TelegramUploadService

    private var durationTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    init(
        settings: AppSettings = .shared,
        audioTap: AudioTapService? = nil,
        recorder: RecordingService? = nil,
        driveService: GoogleDriveService? = nil,
        telegramAuth: TelegramAuthService? = nil,
        telegramUpload: TelegramUploadService? = nil
    ) {
        self.settings = settings
        self.audioTap = audioTap ?? AudioTapService(settings: settings)
        self.recorder = recorder ?? RecordingService(settings: settings)
        self.driveService = driveService ?? GoogleDriveService()
        self.telegramAuth = telegramAuth ?? TelegramAuthService(settings: settings)
        self.telegramUpload = telegramUpload ?? TelegramUploadService(auth: self.telegramAuth)

        loadRecordingsFromDisk()
        wireServices()
    }

    // MARK: - App lifecycle

    func onAppLaunch() async {
        telegramAuth.start()
        await startMonitoring()
    }

    func onAppTerminate() {
        audioTap.stopMonitoring()
        telegramAuth.stop()
    }

    // MARK: - Monitoring

    func startMonitoring() async {
        await audioTap.startMonitoring()
    }

    // MARK: - Service wiring

    private func wireServices() {
        // AudioTap → RecordingService bridge
        audioTap.onCallStarted = { [weak self] session in
            guard let self else { return }
            Task { await self.handleCallStarted(session) }
        }
        audioTap.onCallEnded = { [weak self] session in
            guard let self else { return }
            Task { await self.handleCallEnded(session) }
        }
        audioTap.onAppAudioBuffer = { [weak self] buffer, _ in
            self?.recorder.appendAppBuffer(buffer)
        }

        // RecordingService → upload pipeline
        recorder.onRecordingFinished = { [weak self] url, session, duration in
            guard let self else { return }
            Task { await self.handleRecordingFinished(url: url, session: session, duration: duration) }
        }

        // Google Drive progress
        driveService.onProgress = { [weak self] progress in
            DispatchQueue.main.async { /* update per-recording progress if needed */ }
        }
    }

    // MARK: - Call events

    private func handleCallStarted(_ session: CallSession) async {
        activeSession = session
        startDurationTimer()
        do {
            try recorder.startRecording(session: session)
        } catch {
            appError = "Не вдалося розпочати запис: \(error.localizedDescription)"
        }
    }

    private func handleCallEnded(_ session: CallSession) async {
        stopDurationTimer()
        activeSession = nil
        do {
            _ = try await recorder.stopRecording()
        } catch {
            appError = "Помилка при збереженні запису: \(error.localizedDescription)"
        }
    }

    private func handleRecordingFinished(url: URL, session: CallSession, duration: Double) async {
        var recording = Recording.make(
            session: session,
            fileURL: url,
            duration: duration,
            managerName: settings.managerName
        )
        recordings.insert(recording, at: 0)
        saveRecordingsToDisk()

        await uploadRecording(&recording)
    }

    // MARK: - Upload pipeline

    func uploadRecording(_ recording: inout Recording) async {
        guard let idx = recordings.firstIndex(where: { $0.id == recording.id }) else { return }

        // Google Drive
        if settings.isGoogleDriveEnabled, !settings.googleDriveFolderId.isEmpty {
            recordings[idx].uploadState = .uploadingDrive
            let folderId = await driveService.getOrCreateUserFolder(
                parentId: settings.googleDriveFolderId,
                userName: settings.managerName
            )
            _ = await driveService.upload(fileURL: recording.fileURL, folderId: folderId)
        }

        // Telegram
        if settings.isTelegramAuthorized, settings.telegramChatId != 0 {
            recordings[idx].uploadState = .uploadingTelegram
            let caption = buildCaption(for: recordings[idx])
            await telegramUpload.sendRecording(
                fileURL: recording.fileURL,
                chatId: settings.telegramChatId,
                caption: caption
            )
        }

        recordings[idx].uploadState = .done
        saveRecordingsToDisk()
    }

    func retryUpload(recording: Recording) async {
        guard var rec = recordings.first(where: { $0.id == recording.id }) else { return }
        await uploadRecording(&rec)
    }

    // MARK: - Duration timer

    private func startDurationTimer() {
        recordingDuration = 0
        durationTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let s = self else { return }
            DispatchQueue.main.async { s.recordingDuration += 1 }
        }
    }

    private func stopDurationTimer() {
        durationTimer?.invalidate()
        durationTimer = nil
        recordingDuration = 0
    }

    // MARK: - Persistence (simple JSON on disk)

    private var recordingsCacheURL: URL {
        settings.recordingsDirectory.appendingPathComponent("index.json")
    }

    private func loadRecordingsFromDisk() {
        guard let data = try? Data(contentsOf: recordingsCacheURL),
              let list = try? JSONDecoder().decode([Recording].self, from: data)
        else { return }
        // Filter out recordings whose files no longer exist
        recordings = list.filter { FileManager.default.fileExists(atPath: $0.filePath) }
    }

    func saveRecordingsToDisk() {
        guard let data = try? JSONEncoder().encode(recordings) else { return }
        try? data.write(to: recordingsCacheURL, options: .atomic)
    }

    func deleteRecording(_ recording: Recording) {
        try? FileManager.default.removeItem(at: recording.fileURL)
        recordings.removeAll { $0.id == recording.id }
        saveRecordingsToDisk()
    }

    // MARK: - Caption helper

    private func buildCaption(for rec: Recording) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        let date = formatter.string(from: rec.createdAt)
        let mins = Int(rec.durationSeconds) / 60
        let secs = Int(rec.durationSeconds) % 60
        return "📞 \(rec.appName) · \(rec.managerName)\n🕐 \(date)\n⏱ \(mins):\(String(format: "%02d", secs))"
    }
}
