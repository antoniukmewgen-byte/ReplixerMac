import Foundation
import TDLibKit
import AVFoundation

/// Phase 4.2: sends a finished recording to the configured Telegram
/// chat/topic (`AppSettings.telegramChatId`/`telegramTopicId`), as an
/// inline-playable audio message.
///
/// Windows-parity source: `TelegramUploadService.cs`'s
/// `SendFileCoreAsync`/`BuildCaption`, adapted to TDLibKit's request/
/// response model. TDLib itself already handles the low-level
/// reconnect/backoff that WTelegram (raw MTProto, used on Windows) left to
/// application code to catch by exception type
/// (`NullReferenceException`/`TaskCanceledException` there) — so the
/// one-retry-then-give-up shape here doesn't need to distinguish *why* the
/// send failed the way the Windows original does.
enum TelegramUploadService {
    // No Info.plist/bundle yet (that's Phase 1.1's risk #1 / Phase 7's
    // bundling) to read a real app/build version from — hardcoded
    // placeholder for the caption's version tag, update alongside whatever
    // versioning scheme Phase 7 lands on.
    private static let appVersion = "0.1.0-poc"

    enum UploadError: Swift.Error {
        case missingChatId
    }

    /// Sends `filePath` (expected to be a finished .m4a recording) to
    /// `AppSettings.shared.telegramChatId`/`telegramTopicId`. `caption` is
    /// the message text (Windows default: `"Запис дзвінку: {fileName}"`,
    /// left to the caller here rather than defaulted, since
    /// CallRecordingCoordinator will eventually want to build a richer one).
    /// `driveUrl`, mirroring `BuildCaption`'s Drive-URL line, is unused
    /// until Phase 5 wires Google Drive upload in — passing one now already
    /// produces Windows-parity caption text.
    ///
    /// Retries exactly once, after a fixed 2s delay, on any thrown error —
    /// same "one retry, then surface the failure" shape as Windows' inline
    /// retry, just without needing to special-case which specific exception
    /// types are worth retrying.
    static func sendRecording(
        filePath: String,
        caption: String,
        driveUrl: String? = nil,
        client: TDLibClient,
        isRetry: Bool = false
    ) async throws -> Int64 {
        guard let chatId = AppSettings.shared.telegramChatId else {
            throw UploadError.missingChatId
        }
        let topicId = AppSettings.shared.telegramTopicId
        let messageTopic: MessageTopic? = topicId.map { .messageTopicForum(MessageTopicForum(forumTopicId: $0)) }

        let fileName = (filePath as NSString).lastPathComponent
        let content = InputMessageContent.inputMessageAudio(InputMessageAudio(
            audio: InputAudio(
                albumCoverThumbnail: nil,
                audio: .inputFileLocal(InputFileLocal(path: filePath)),
                duration: audioDuration(atPath: filePath),
                performer: "",
                title: fileName
            ),
            caption: FormattedText(entities: [], text: buildCaption(caption, driveUrl: driveUrl))
        ))

        do {
            let sent = try await client.sendMessage(
                chatId: chatId,
                inputMessageContent: content,
                options: nil,
                replyMarkup: nil,
                replyTo: nil,
                topicId: messageTopic
            )
            return sent.id
        } catch {
            guard !isRetry else { throw error }
            print("[TelegramUploadService] ⚠️ відправка не вдалась (\(error)), повторна спроба через 2с...")
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return try await sendRecording(filePath: filePath, caption: caption, driveUrl: driveUrl, client: client, isRetry: true)
        }
    }

    /// Windows parity: `BuildCaption` appends `"\n💾 Google Drive: {url}"`
    /// before the version tag when a Drive URL is present, then always
    /// appends `"\n🔖 v{version}"` last. `CaptionHelper.SplitHashtagSuffix`
    /// (which keeps a trailing `#hashtag` line last, after the version tag)
    /// isn't ported — nothing in this app generates hashtag captions yet,
    /// so there's nothing for it to reorder; revisit if that changes.
    private static func buildCaption(_ caption: String, driveUrl: String?) -> String {
        var text = caption
        if let driveUrl, !driveUrl.isEmpty {
            text += "\n💾 Google Drive: \(driveUrl)"
        }
        text += "\n🔖 v\(appVersion)"
        return text
    }

    /// Best-effort duration hint for the audio bubble's scrubber — TDLib
    /// docs note the server may replace this anyway, so a failed read (0)
    /// degrades gracefully rather than blocking the send.
    private static func audioDuration(atPath path: String) -> Int {
        guard let file = try? AVAudioFile(forReading: URL(fileURLWithPath: path)) else { return 0 }
        let seconds = Double(file.length) / file.fileFormat.sampleRate
        return Int(seconds.rounded())
    }
}
