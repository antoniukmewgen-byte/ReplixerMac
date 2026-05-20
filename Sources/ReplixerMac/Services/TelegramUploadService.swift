import Foundation
import AVFoundation
import CoreMedia
import TDLibKit

@MainActor
final class TelegramUploadService {

    private let auth: TelegramAuthService
    private weak var api: TdApi?

    var onCompleted: (() -> Void)?
    var onFailed:    ((String) -> Void)?

    init(auth: TelegramAuthService) {
        self.auth = auth
    }

    func setApi(_ api: TdApi) { self.api = api }

    // MARK: - Upload

    func sendRecording(fileURL: URL, chatId: Int64, caption: String) async {
        guard let api else { onFailed?("TDLib not initialized"); return }
        guard auth.authState == .ready else { onFailed?("Telegram не авторизовано"); return }
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            onFailed?("Файл не знайдено: \(fileURL.lastPathComponent)"); return
        }

        do {
            let durationSecs = Int(await assetDuration(fileURL))
            let formattedCaption = FormattedText(entities: [], text: caption)

            let audioContent = InputMessageAudio(
                albumCoverThumbnail: nil,
                audio: .inputFileLocal(.init(path: fileURL.path)),
                caption: formattedCaption,
                duration: durationSecs,
                performer: "",
                title: fileURL.deletingPathExtension().lastPathComponent
            )

            let content = InputMessageContent.inputMessageAudio(audioContent)

            _ = try await api.sendMessage(
                chatId: chatId,
                inputMessageContent: content,
                options: nil,
                replyMarkup: nil,
                replyTo: nil,
                topicId: nil
            )

            onCompleted?()
        } catch {
            onFailed?(error.localizedDescription)
        }
    }

    func findChat(query: String) async -> Int64? {
        guard let api else { return nil }
        if let id = Int64(query) { return id }
        guard query.hasPrefix("@") else { return nil }
        let username = String(query.dropFirst())
        return try? await api.searchPublicChat(username: username).id
    }

    // MARK: - Helpers

    private func assetDuration(_ url: URL) async -> Double {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        return CMTimeGetSeconds(duration)
    }
}
