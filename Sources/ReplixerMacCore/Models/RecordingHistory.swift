import Foundation

/// In-memory + persisted (`recordings.json`) history of recordings.
/// Windows parity source: `RecordingsViewModel.cs`'s load/save logic,
/// without the UI-facing `ObservableCollection`/`CommandManager` pieces.
/// Mutated by CallRecordingCoordinator (an actor) as calls start/end/
/// upload; read by RecordingsView (Phase 7.4, main thread) to display
/// history.
///
/// Thread-safe (lock-protected `_entries`, see below) since Phase 7.4 —
/// before that, every call into this class happened from
/// CallRecordingCoordinator's single serialized actor executor, so no
/// synchronization was needed. Not an actor itself: nothing here ever needs
/// to `await` while holding the lock, so a plain `NSLock` is enough and
/// avoids forcing every call site (several of them synchronous, non-async
/// methods on CallRecordingCoordinator) to become `async` just to reach it.
public final class RecordingHistory {
    public static let shared = RecordingHistory()

    public static let store = JSONStore<[RecordingEntry]>(url:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReplixerMac", isDirectory: true)
            .appendingPathComponent("recordings.json")
    )

    // Posted (from whatever thread the mutation happened on — usually
    // CallRecordingCoordinator's actor executor, not the main thread) after
    // every change to `entries`. Phase 7.4: RecordingsView observes this to
    // refresh instead of ReplixerMacCore depending on Combine/SwiftUI
    // directly (Phase 7's headless-core split) — observers must hop to the
    // main actor themselves before touching UI state, e.g. via
    // `.receive(on: DispatchQueue.main)`.
    public static let didChangeNotification = Notification.Name("ReplixerMac.RecordingHistory.didChange")

    // Every mutating method here was, until Phase 7.4, only ever called
    // from CallRecordingCoordinator's actor executor — a single serialized
    // context, so `entries` never needed its own synchronization. Phase
    // 7.4 adds a second, genuinely concurrent reader (RecordingsView, on
    // the main thread), so unprotected access is now a real data race, not
    // just a theoretical one — a lock is enough here (not another actor):
    // every operation below is a quick, synchronous, in-memory array edit,
    // never something that needs to `await` while holding it.
    private let lock = NSLock()
    private var _entries: [RecordingEntry]

    /// Thread-safe snapshot. Safe to call from any thread/actor — copies
    /// out under the lock rather than exposing the live array, so the
    /// caller's copy can never be torn by a concurrent mutation.
    public var entries: [RecordingEntry] {
        lock.lock()
        defer { lock.unlock() }
        return _entries
    }

    private init() {
        switch RecordingHistory.store.load() {
        case .decoded(let loaded):
            _entries = loaded
        case .notFound:
            _entries = []
        case .decodeFailed(let error):
            // Unlike AppSettings.load(), there's no immediate saveNow()
            // here to guard against — but starting from an empty array and
            // letting a later addStarted()/markFinished() scheduleSave()
            // silently overwrite a corrupt-but-recoverable recordings.json
            // would still quietly destroy history. Surface it instead so a
            // hand-edit mistake (or real corruption) gets fixed rather than
            // paved over.
            print("[RecordingHistory] ❌ не вдалося прочитати \(RecordingHistory.store.url.path): \(error)")
            print("[RecordingHistory] ⚠️ Стартую з порожньою історією в пам'яті — файл на диску поки НЕ буде перезаписано, але зверни увагу, якщо це неочікувано.")
            _entries = []
        }
    }

    /// Runs `body` under the lock; if it reports something actually
    /// changed, schedules a debounced save and notifies observers outside
    /// the lock (so a re-entrant observer can't deadlock on it). Every
    /// mutating method below funnels through this so "change the array" and
    /// "persist + tell the UI" can never accidentally drift apart.
    private func mutate(_ body: (inout [RecordingEntry]) -> Bool) {
        let didChange: Bool
        let snapshot: [RecordingEntry]
        lock.lock()
        didChange = body(&_entries)
        snapshot = _entries
        lock.unlock()
        guard didChange else { return }
        RecordingHistory.store.scheduleSave(snapshot)
        NotificationCenter.default.post(name: RecordingHistory.didChangeNotification, object: nil)
    }

    /// JSON-level counterpart of `FileNaming.cleanupStalePartialFiles()`: any
    /// entry still in `.recording` status at startup means the process died
    /// (crash/`kill -9`) before `markFinished`/`markFailed` ever ran for it —
    /// a live process would have already transitioned it. Left as `.recording`
    /// forever, it would look like an ongoing call in a future history UI even
    /// though the underlying file was already swept away by
    /// `cleanupStalePartialFiles()`. Call once at startup, right alongside
    /// that file-level sweep, so the two stay in sync.
    ///
    /// Returns the number of entries reconciled, purely so main.swift's
    /// startup log can report it — no other caller needs the count.
    @discardableResult
    public func reconcileDanglingRecordings() -> Int {
        var count = 0
        mutate { entries in
            for index in entries.indices where entries[index].status == .recording {
                entries[index].status = .error
                count += 1
            }
            return count > 0
        }
        return count
    }

    /// Records a call starting. Returns the new entry's id so the caller
    /// can pass it back to `markFinished`/`markFailed` without needing to
    /// search the array by, e.g., start time (which isn't guaranteed
    /// unique) when the call ends.
    ///
    /// Known gap (fine for now, revisit if it matters later): an entry
    /// left in `.recording` status because the app crashed/`kill -9`ed
    /// mid-call is never reconciled to `.error` — it just sits there
    /// looking perpetually in-progress. FileNaming.cleanupStalePartialFiles()
    /// already detects this exact situation for the underlying file at
    /// startup; once a Phase 7 UI actually displays history status, wire
    /// that sweep to also flip any dangling `.recording` entries to
    /// `.error` at the same point.
    @discardableResult
    func addStarted(platform: String) -> UUID {
        let entry = RecordingEntry(platform: platform)
        mutate { entries in
            entries.insert(entry, at: 0)
            return true
        }
        return entry.id
    }

    func markFinished(id: UUID, filePath: String) {
        mutate { entries in
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
            entries[index].filePath = filePath
            entries[index].status = .saved
            entries[index].callDuration = Date().timeIntervalSince(entries[index].startedAt)
            return true
        }
    }

    func markFailed(id: UUID) {
        mutate { entries in
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
            entries[index].status = .error
            return true
        }
    }

    /// Phase 10.0: records the caption a just-finished (or just-retried)
    /// upload used/will use, for the case where no report form was shown at
    /// all (the generic "Запис дзвінку: {fileName}" fallback) — a
    /// *submitted* call-report's caption goes through `updateReportData`
    /// instead, since that also has `reportData` itself to persist. Set
    /// once, right before the corresponding upload attempt kicks off, so
    /// `beginRetryCandidates`'s callers can reuse the exact same text on a
    /// later retry instead of reconstructing a different (report-less) one.
    func updateCaption(id: UUID, caption: String) {
        mutate { entries in
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
            entries[index].caption = caption
            return true
        }
    }

    /// Phase 6: records the outcome of an upload attempt (initial or
    /// retried) for `id`. Takes the full final state rather than optional
    /// "only touch what changed" params — `UploadOrchestrator.Result`
    /// always carries the definitive value for each field (an
    /// already-succeeded step it was told to skip comes back unchanged, not
    /// nil), so there's never a need to distinguish "don't touch" from
    /// "set to nil/false" here.
    func updateUploadState(id: UUID, driveUrl: String?, driveFailed: Bool, telegramMessageId: Int64?, telegramFailed: Bool, kommoNoteId: Int64?) {
        mutate { entries in
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
            entries[index].driveUrl = driveUrl
            entries[index].driveFailed = driveFailed
            entries[index].telegramMessageId = telegramMessageId
            entries[index].telegramFailed = telegramFailed
            entries[index].kommoNoteId = kommoNoteId
            return true
        }
    }

    /// Records a submitted call-report's data alongside its formatted
    /// caption. Two call sites:
    ///
    /// - `finishRecording`/`resumeDraft`'s `.submitted` branch — persists
    ///   the just-filled-in report so a later `editReport` has something to
    ///   prefill the form with (before this existed, only `caption` was
    ///   saved via `updateCaption`, and `entry.reportData` stayed `nil`
    ///   forever, leaving the edit form empty).
    /// - `CallRecordingCoordinator.editReport`'s full-success path —
    ///   Windows parity: `HomeViewModel.EditEntryReportAsync`'s `entry
    ///   .ReportData = newData;`. Only called once both the
    ///   Telegram-caption-edit and Kommo-note-edit legs succeed (or were
    ///   skipped) — a partial failure leaves the entry's old `reportData`/
    ///   `caption` in place rather than recording a caption that doesn't
    ///   actually match what's sitting in Telegram/Kommo.
    ///
    /// `kommoNoteId` is deliberately left untouched here either way —
    /// nothing about submitting/editing report text creates a *new* Kommo
    /// note, so there's never a new id to record.
    func updateReportData(id: UUID, reportData: CallReportData, caption: String) {
        mutate { entries in
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
            entries[index].reportData = reportData
            entries[index].caption = caption
            return true
        }
    }

    /// Phase 11.4 — Windows parity: `EditEntryReportAsync`'s `entry
    /// .TelegramMessageId = null;` when the Telegram edit comes back with
    /// `TelegramUploadService.MessageDeletedWarning` — the message was
    /// deleted out from under the app (e.g. by hand in the Telegram app
    /// itself), so the stored id no longer points at anything editable.
    /// Cleared unconditionally, independent of whether the rest of the edit
    /// (Kommo's leg) succeeded — same as Windows checking this before its
    /// `tgError is null && kommoError is null` success branch.
    func clearTelegramMessageId(id: UUID) {
        mutate { entries in
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
            entries[index].telegramMessageId = nil
            return true
        }
    }

    /// Phase 11.3 — Windows parity: `StopRecordingAsync`'s `wasInterrupted`
    /// branch (`entry.ReportData = _interruptedDraft; entry.Status =
    /// RecordingStatus.Draft;`). Called instead of `markFinished`'s upload
    /// path when the call-report form got interrupted by a new call before
    /// the user submitted it — no upload is attempted for a draft; the only
    /// way back to `.saved`/`.error` is `resumeDraft`/`markDraftResolved`
    /// below. `reportData` may itself be nil (interrupted before the user
    /// typed anything at all) — still worth marking `.draft` rather than
    /// silently discarding the recording the way a report-less call end
    /// would, since Windows doesn't fall back to the no-report caption here
    /// either.
    func markDraft(id: UUID, reportData: CallReportData?) {
        mutate { entries in
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
            entries[index].status = .draft
            entries[index].reportData = reportData
            return true
        }
    }

    /// Phase 11.3: flips a `.draft` entry back to `.saved`/`.error` once
    /// `CallRecordingCoordinator.resumeDraft`'s upload attempt finishes.
    /// Deliberately doesn't touch `callDuration`/`filePath` the way
    /// `markFinished` does — both were already recorded correctly when the
    /// call originally ended; recomputing `callDuration` from `Date()` here
    /// would wrongly stretch it to cover however long the draft sat waiting
    /// to be resumed.
    func markDraftResolved(id: UUID, succeeded: Bool) {
        mutate { entries in
            guard let index = entries.firstIndex(where: { $0.id == id }) else { return false }
            entries[index].status = succeeded ? .saved : .error
            return true
        }
    }

    /// Phase 6: snapshot of entries whose last upload attempt left
    /// something unfinished, atomically marked `isBackgroundRetrying` in
    /// the same pass — mirrors Windows PendingUploadRetryService's
    /// candidates-then-mark-in-one-step approach, so a slow retry tick and
    /// a hypothetical future manual "retry now" action can't both grab the
    /// same entry. `isBackgroundRetrying` isn't persisted (see
    /// RecordingEntry), so no save is scheduled here.
    func beginRetryCandidates() -> [RecordingEntry] {
        // Not routed through `mutate`: `isBackgroundRetrying` is
        // deliberately unpersisted (see RecordingEntry), so this
        // intentionally skips both the scheduleSave and the UI-refresh
        // notification `mutate` would otherwise trigger — same behavior as
        // before the lock existed, just now safe to call concurrently with
        // a RecordingsView read.
        lock.lock()
        defer { lock.unlock() }
        var candidates: [RecordingEntry] = []
        for index in _entries.indices where _entries[index].needsBackgroundRetry && !_entries[index].isBackgroundRetrying {
            _entries[index].isBackgroundRetrying = true
            candidates.append(_entries[index])
        }
        return candidates
    }

    /// Releases the in-progress flag `beginRetryCandidates` set, regardless
    /// of whether the retry succeeded — call in every code path (success,
    /// partial success, or the entry's file having vanished) so an entry
    /// can never get stuck permanently skipped.
    func endBackgroundRetry(id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = _entries.firstIndex(where: { $0.id == id }) else { return }
        _entries[index].isBackgroundRetrying = false
    }

    /// Forces any pending debounced save to happen immediately — call
    /// before process exit, same reasoning as AppSettings.flush().
    public func flush() {
        RecordingHistory.store.saveNow(entries)
    }
}
