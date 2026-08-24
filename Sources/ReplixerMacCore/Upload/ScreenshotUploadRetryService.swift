import Foundation

/// Background retry queue for screenshots (captured via "Швидкі дії" in the
/// missed-call report form) that failed to upload to Google Drive right
/// away — mirrors `MissedCallDeliveryService`'s exact queue/persist/retry
/// shape. Windows parity source: `Services/Upload
/// /PendingScreenshotUploadRetryService.cs` + `Models
/// /PendingScreenshotUpload.cs`.
///
/// If the missed-call report form gets submitted before a queued screenshot
/// finishes uploading in the background, the link isn't lost: once the
/// upload succeeds, this posts a *separate* Kommo note with the late link
/// (`kommoLeadUrl`) rather than trying to retroactively patch the
/// already-sent report note or Sheets row — same as Windows'
/// `RetryOneAsync`.
///
/// One deliberate deviation from Windows: `PendingScreenshotUpload.folderId`
/// can be `nil` (folder resolution itself failed before upload was even
/// attempted) — Windows' `RetryOneAsync` just keeps passing that `null`
/// straight through to `UploadAsync` forever, which never recovers even
/// once Drive is configured. Here, a `nil` folder id gets re-resolved via
/// `GoogleDriveUploadService.resolveScreenshotsFolder()` on every attempt
/// instead, since Mac's `upload(filePath:folderId:)` requires a real folder
/// id up front and re-resolving is cheap (cached after the first hit, see
/// that type's doc comment).
///
/// Uses a plain `Task` loop (10s `Task.sleep`) instead of Windows'
/// `System.Threading.Timer`, same as `MissedCallDeliveryService`/
/// `PendingUploadRetryService`.
public final class ScreenshotUploadRetryService {
    public static let shared = ScreenshotUploadRetryService()

    private static let intervalNanoseconds: UInt64 = 10_000_000_000 // 10s, Windows-parity interval

    private static let store = JSONStore<[PendingScreenshotUpload]>(url:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReplixerMac", isDirectory: true)
            .appendingPathComponent("pending_screenshots.json")
    )

    private let lock = NSLock()
    private var _pending: [PendingScreenshotUpload]
    // De-dup guard: an enqueue-triggered immediate attempt and the next 10s
    // tick could otherwise both pick up the same still-queued item — same
    // reasoning as MissedCallDeliveryService.inFlight.
    private var inFlight: Set<UUID> = []
    private var task: Task<Void, Never>?

    private init() {
        switch ScreenshotUploadRetryService.store.load() {
        case .decoded(let loaded):
            _pending = loaded
        case .notFound:
            _pending = []
        case .decodeFailed(let error):
            print("[ScreenshotUploadRetryService] ❌ не вдалося прочитати \(ScreenshotUploadRetryService.store.url.path): \(error)")
            print("[ScreenshotUploadRetryService] ⚠️ Стартую з порожньою чергою — файл на диску поки НЕ буде перезаписано.")
            _pending = []
        }
    }

    public func start() {
        guard task == nil else { return } // already running
        task = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: ScreenshotUploadRetryService.intervalNanoseconds)
                guard !Task.isCancelled else { return }
                guard let self else { return }
                await self.tick()
            }
        }
        print("[ScreenshotUploadRetryService] 🔁 фоновий сервіс довантаження скріншотів запущено (кожні 10с)")
    }

    /// Call before process exit — same reasoning as
    /// `PendingUploadRetryService.stop()`.
    public func stop() {
        task?.cancel()
        task = nil
    }

    /// Called right after an inline screenshot upload fails (see
    /// `MissedCallQuickActionService.captureAndUpload`'s `.uploadFailed`
    /// paths): queues the file — so it survives even a crash before the
    /// next successful attempt — and immediately tries once more, same
    /// "maybe it was just a one-off network hiccup" reasoning as
    /// `MissedCallDeliveryService.submit`.
    public func enqueue(localPath: String, folderId: String?, messenger: String, kommoLeadUrl: String?) {
        let entry = PendingScreenshotUpload(
            id: UUID(), localPath: localPath, folderId: folderId,
            messenger: messenger, kommoLeadUrl: kommoLeadUrl, capturedAt: Date()
        )
        lock.lock()
        _pending.append(entry)
        let snapshot = _pending
        lock.unlock()
        ScreenshotUploadRetryService.store.scheduleSave(snapshot)

        Task { await attemptUpload(entry, isFirstAttempt: true) }
    }

    // Swift 6: `NSLock.lock()`/`unlock()` are unavailable to call directly
    // from inside an `async` function body — same fix shape as
    // MissedCallDeliveryService's identical helpers.
    private func snapshotPending() -> [PendingScreenshotUpload] {
        lock.lock()
        defer { lock.unlock() }
        return _pending
    }

    private func beginInFlight(_ id: UUID) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !inFlight.contains(id) else { return false }
        inFlight.insert(id)
        return true
    }

    private func endInFlight(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        inFlight.remove(id)
    }

    private func tick() async {
        let snapshot = snapshotPending()
        for item in snapshot {
            await attemptUpload(item, isFirstAttempt: false)
        }
    }

    /// Windows parity source: `RetryOneAsync`.
    private func attemptUpload(_ item: PendingScreenshotUpload, isFirstAttempt: Bool) async {
        guard beginInFlight(item.id) else { return }
        defer { endInFlight(item.id) }

        guard FileManager.default.fileExists(atPath: item.localPath) else {
            print("[ScreenshotUploadRetryService] ⚠️ локальний файл зник, знімаю із черги: \(item.localPath)")
            removeFromQueue(item.id)
            return
        }

        let folderId: String?
        if let existing = item.folderId, !existing.isEmpty {
            folderId = existing
        } else {
            folderId = await GoogleDriveUploadService.resolveScreenshotsFolder()
        }
        guard let folderId else {
            // Still not configured — stays queued, try again next tick.
            return
        }

        do {
            let url = try await GoogleDriveUploadService.upload(filePath: item.localPath, folderId: folderId)
            removeFromQueue(item.id)
            try? FileManager.default.removeItem(atPath: item.localPath)

            if let kommoLeadUrl = item.kommoLeadUrl, !kommoLeadUrl.isEmpty {
                let note = "📎 Скрін (\(item.messenger)), довантажено пізніше: \(url)"
                do {
                    _ = try await KommoService.addNote(crmUrl: kommoLeadUrl, text: note)
                } catch {
                    print("[ScreenshotUploadRetryService] ⚠️ скрін довантажено, але нотатку в Kommo додати не вдалось: \(error)")
                }
            }

            NotificationService.showSuccess("Скріншот (\(item.messenger)), який раніше не вдалось завантажити, тепер збережено на Google Drive.")
        } catch {
            if isFirstAttempt {
                print("[ScreenshotUploadRetryService] ⚠️ перша спроба довантажити скрін \(item.id) не вдалась: \(error)")
            } else {
                print("[ScreenshotUploadRetryService] ⚠️ повтор довантаження скрін \(item.id) не вдався: \(error)")
            }
        }
    }

    private func removeFromQueue(_ id: UUID) {
        lock.lock()
        _pending.removeAll { $0.id == id }
        let snapshot = _pending
        lock.unlock()
        ScreenshotUploadRetryService.store.scheduleSave(snapshot)
    }

    /// Forces any pending debounced save to happen immediately — call
    /// before process exit, same reasoning as `MissedCallDeliveryService.flush()`.
    public func flush() {
        lock.lock()
        let snapshot = _pending
        lock.unlock()
        ScreenshotUploadRetryService.store.saveNow(snapshot)
    }
}
