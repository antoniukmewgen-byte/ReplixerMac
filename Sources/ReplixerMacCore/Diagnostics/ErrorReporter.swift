import Foundation

/// Ports Windows' `Services/ErrorReporter.cs` — a separate Telegram Bot-API
/// channel (NOT the user-session TDLib upload path `TelegramUploadService`
/// uses for recordings) that developers watch for crashes/operational
/// errors from the field. Every message this sends carries a "· Replixer
/// MacOS" tag (see `formatMessage` below) — Windows' own ErrorReporter
/// messages carry no such tag, and per the user's explicit request both
/// apps' reports may land in the very same Telegram chat(s), so the tag is
/// the only thing that tells a developer reading the channel which
/// platform actually produced a given report.
///
/// Architecture differences from Windows, and why:
///   - Windows wires three global handlers (`DispatcherUnhandledException`,
///     `AppDomain.UnhandledException`, `TaskScheduler.UnobservedTaskException`),
///     all of which run in a still-fully-alive CLR with the exception
///     object in hand. Swift has no equivalent for its own fatal traps
///     (force-unwrap, array-out-of-bounds, integer overflow) —
///     `fatalError`/`Builtin.trap()` call straight into `abort()` with no
///     interception point in pure Swift, and hand-writing a raw POSIX
///     signal handler correctly (async-signal-safe, zero allocation) isn't
///     something this port can safely author or verify blind (no Mac
///     available to compile/run against, only the person testing builds on
///     their own machine). So: `NSSetUncaughtExceptionHandler` (wired in
///     `ReplixerMacApp`'s `AppDelegate`) covers the subset of crashes that
///     surface as an Objective-C `NSException` — a real, if partial, source
///     of AppKit-adjacent crashes — and `AppDelegate`'s existing dangling-
///     recording reconciliation at startup (`RecordingHistory
///     .reconcileDanglingRecordings()`, already there since Phase 7.5)
///     doubles as a "previous run almost certainly crashed mid-recording"
///     signal. Both funnel into `persistCrashSynchronously` below rather
///     than needing a dedicated fatal-signal handler.
///   - `actor`, not Windows' static class + manual locking — the in-memory
///     retry queue only needs to be safe against concurrent `report()`
///     calls from different upload paths (Telegram/Drive/Kommo can all fail
///     around the same time), which an actor gives for free.
public actor ErrorReporter {
    public static let shared = ErrorReporter()

    // MARK: - Persisted retry queue

    struct QueuedError: Codable {
        let timestamp: Date
        let user: String
        let appVersion: String
        let category: String
        let message: String
        let detail: String?
    }

    private static let queueStore = JSONStore<[QueuedError]>(url:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReplixerMac", isDirectory: true)
            .appendingPathComponent("error_queue.json")
    )

    // Windows parity: ErrorReporter.cs caps its persisted queue at 50
    // entries, oldest dropped first — a runaway repeated failure (e.g. no
    // internet for days) shouldn't grow this file unboundedly.
    private static let maxQueueSize = 50

    // Windows parity: FlushQueueAsync's 5-minute Timer interval.
    private static let flushIntervalNanoseconds: UInt64 = 5 * 60 * 1_000_000_000

    private var queue: [QueuedError]
    private var flushTask: Task<Void, Never>?

    private init() {
        switch Self.queueStore.load() {
        case .decoded(let loaded):
            queue = loaded
        case .notFound, .decodeFailed:
            // Unlike AppSettings.load(), a corrupt/missing queue file is
            // never worth failing startup over — it's just a best-effort
            // log of past failures, not user data. Start fresh; the next
            // enqueue overwrites it with a valid file again.
            queue = []
        }
    }

    /// Call once at app launch (`AppDelegate.applicationDidFinishLaunching`)
    /// — starts the periodic flush loop and makes an immediate attempt to
    /// drain whatever's left over from the previous run, same as Windows'
    /// `Configure()` + `FlushQueueAsync()` pair at startup.
    public func start() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            await self?.flushQueue()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: ErrorReporter.flushIntervalNanoseconds)
                guard !Task.isCancelled else { return }
                await self?.flushQueue()
            }
        }
        print("[ErrorReporter] 🔁 фоновий сервіс звітів про помилки запущено (кожні 5хв)")
    }

    /// Call before process exit — same "don't let a stray background task
    /// outlive shutdown" reasoning as `PendingUploadRetryService.stop()`.
    public func stop() {
        flushTask?.cancel()
        flushTask = nil
    }

    // MARK: - Reporting

    /// Non-fatal operational error — the Mac equivalent of the many
    /// `ErrorReporter.Report(...)` call sites scattered across Windows'
    /// upload services/view models. Tries to send immediately; on any
    /// failure (no network, bad token, Telegram API error) the report is
    /// queued to disk instead of being lost, same as Windows.
    public func report(category: String, message: String, error: Swift.Error? = nil) async {
        // Windows parity: `ErrorReporter.cs:41` calls `NotificationService
        // .ShowError` inside `Report`, unconditionally — the toast fires
        // regardless of whether the report itself sends immediately or
        // ends up queued below.
        NotificationService.showError(message)

        let entry = QueuedError(
            timestamp: Date(),
            user: AppSettings.shared.managerName,
            appVersion: ErrorReporter.currentAppVersion,
            category: category,
            message: message,
            detail: error.map { String(describing: $0) }
        )
        let sent = await ErrorReporter.send(entry)
        if !sent {
            enqueue(entry)
        }
    }

    /// Drains the queue front-to-back, stopping at the first failure — same
    /// as Windows' `FlushQueueAsync` (no point trying entry #2 if entry #1
    /// just failed on what's almost certainly a still-down network).
    /// Mutates `queue` directly rather than a local copy so a `report()`
    /// call that interleaves mid-flush (this method suspends on every
    /// network `await`) still lands in the persisted file at the end.
    public func flushQueue() async {
        guard !queue.isEmpty else { return }
        while let first = queue.first {
            guard await ErrorReporter.send(first) else { break }
            queue.removeFirst()
        }
        ErrorReporter.queueStore.saveNow(queue)
    }

    private func enqueue(_ entry: QueuedError) {
        queue.append(entry)
        if queue.count > ErrorReporter.maxQueueSize {
            queue.removeFirst(queue.count - ErrorReporter.maxQueueSize)
        }
        ErrorReporter.queueStore.saveNow(queue)
    }

    // MARK: - Crash path (best effort — see type doc comment)

    /// Called from `NSSetUncaughtExceptionHandler` and from
    /// `AppDelegate`'s dangling-recording-reconciliation check — both
    /// contexts where the process may not stay alive long enough for an
    /// `await` chain through the actor to complete, so this persists
    /// straight to disk, synchronously, bypassing the actor's in-memory
    /// `queue` entirely (nothing here touches actor-isolated state; that's
    /// what makes it safe to call from a plain, non-`async` context). What
    /// lands here gets picked up and actually sent the next time `start()`
    /// runs and loads the queue fresh off disk. Same "guarantee the write
    /// survives even if a network send never gets the chance" priority as
    /// Windows' `ReportCrash` writing its queue file before ever attempting
    /// to send.
    public nonisolated static func persistCrashSynchronously(category: String, message: String, detail: String? = nil) {
        var existing: [QueuedError]
        switch queueStore.load() {
        case .decoded(let loaded): existing = loaded
        case .notFound, .decodeFailed: existing = []
        }
        existing.append(QueuedError(
            timestamp: Date(),
            user: AppSettings.shared.managerName,
            appVersion: currentAppVersion,
            category: category,
            message: message,
            detail: detail
        ))
        if existing.count > maxQueueSize {
            existing.removeFirst(existing.count - maxQueueSize)
        }
        queueStore.saveNow(existing)
    }

    // MARK: - Sending

    /// `true` only once every configured chat id has accepted every chunk —
    /// same all-or-queue semantics as Windows (a partial send across chat
    /// ids isn't tracked separately; the whole report is retried as one
    /// unit on the next flush).
    private static func send(_ entry: QueuedError) async -> Bool {
        guard !AppSecrets.errorBotToken.isEmpty, !AppSecrets.errorChatIds.isEmpty else {
            // Not configured in this build — same silent-skip treatment
            // AppSecrets' other optional fields get elsewhere in this
            // codebase (e.g. GoogleServiceAccountAuth with an empty
            // googleServiceAccountJson). Returning true here (not false)
            // deliberately avoids growing error_queue.json forever on a
            // build that was never given an error-bot token to begin with.
            return true
        }
        let text = formatMessage(
            category: entry.category, message: entry.message, detail: entry.detail,
            user: entry.user, appVersion: entry.appVersion, timestamp: entry.timestamp)
        let chunks = splitIntoChunks(text)
        for chatId in AppSecrets.errorChatIds {
            for chunk in chunks {
                guard await sendChunk(chunk, to: chatId) else { return false }
            }
        }
        return true
    }

    private static func sendChunk(_ chunk: String, to chatId: Int64) async -> Bool {
        guard let url = URL(string: "https://api.telegram.org/bot\(AppSecrets.errorBotToken)/sendMessage") else {
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let body = try? JSONSerialization.data(withJSONObject: ["chat_id": chatId, "text": chunk]) else {
            return false
        }
        request.httpBody = body
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    // MARK: - Message formatting

    // Same pattern as TelegramUploadService.appVersion/SettingsView
    // .appVersion — reads Info.plist's real CFBundleShortVersionString once
    // packaged, falls back to the placeholder for contexts with no
    // Info.plist at all (ReplixerMacCallPoC, unit tests).
    private static var currentAppVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0-poc"
    }

    private static func statusGlyph(enabled: Bool, connected: Bool) -> String {
        guard enabled else { return "вимк." }
        return connected ? "✅" : "❌"
    }

    /// Windows parity: `ErrorReporter.FormatMessage` — icon + category,
    /// user + version line, timestamp, integration-status line, blank line,
    /// message body, optional exception detail. The one deliberate
    /// difference (besides the "· Replixer MacOS" tag) is the integration
    /// line's source: Windows reads its own `AppSettings`/connection-test
    /// state, mirrored here 1:1 from `AppSettings.shared`'s
    /// isGoogleDriveEnabled/isDriveConnected, isTelegramEnabled/
    /// telegramChatId/telegramPhone, isKommoEnabled/isKommoConnected.
    private static func formatMessage(
        category: String, message: String, detail: String?,
        user: String, appVersion: String, timestamp: Date
    ) -> String {
        let icon = category.hasPrefix("CRASH") ? "💥" : "⚠️"
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")

        let settings = AppSettings.shared
        let driveStatus = statusGlyph(enabled: settings.isGoogleDriveEnabled, connected: settings.isDriveConnected)
        let telegramStatus = settings.isTelegramEnabled ? (settings.telegramChatId != nil ? "✅" : "❌") : "вимк."
        let telegramPhoneSuffix = settings.telegramPhone.map { " (\($0))" } ?? ""
        let kommoStatus = statusGlyph(enabled: settings.isKommoEnabled, connected: settings.isKommoConnected)

        var text = """
        \(icon) \(category) · Replixer MacOS
        👤 \(user)  |  v\(appVersion)
        🕐 \(formatter.string(from: timestamp))

        🔌 Google Drive: \(driveStatus)  |  Telegram: \(telegramStatus)\(telegramPhoneSuffix)  |  Kommo: \(kommoStatus)

        \(message)
        """
        if let detail, !detail.isEmpty {
            text += "\n\n\(detail)"
        }
        return text
    }

    /// Windows parity: `ErrorReporter.SplitIntoChunks` — Telegram's
    /// `sendMessage` caps `text` at 4096 characters; break on the last
    /// newline inside the window when one exists, so a chunk boundary
    /// doesn't land mid-line.
    private static func splitIntoChunks(_ text: String, maxLength: Int = 4096) -> [String] {
        var chunks: [String] = []
        var start = text.startIndex
        while start < text.endIndex {
            var end = text.index(start, offsetBy: maxLength, limitedBy: text.endIndex) ?? text.endIndex
            if end < text.endIndex, let newlineIndex = text[start..<end].lastIndex(of: "\n") {
                let candidate = text.index(after: newlineIndex)
                if candidate > start {
                    end = candidate
                }
            }
            chunks.append(String(text[start..<end]))
            start = end
        }
        return chunks
    }
}
