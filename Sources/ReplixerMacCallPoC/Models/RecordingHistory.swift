import Foundation

/// In-memory + persisted (`recordings.json`) history of recordings.
/// Windows parity source: `RecordingsViewModel.cs`'s load/save logic,
/// without the UI-facing `ObservableCollection`/`CommandManager` pieces —
/// no UI exists yet (Phase 7). Driven directly by CallRecordingCoordinator
/// as calls start/end.
///
/// Not an actor/thread-safe type on its own — every call into this class
/// currently happens from CallRecordingCoordinator, which is itself an
/// actor, so calls are already serialized by the time they get here. If a
/// future phase calls this from elsewhere too, that assumption needs
/// revisiting.
final class RecordingHistory {
    static let shared = RecordingHistory()

    static let store = JSONStore<[RecordingEntry]>(url:
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReplixerMac", isDirectory: true)
            .appendingPathComponent("recordings.json")
    )

    private(set) var entries: [RecordingEntry]

    private init() {
        entries = RecordingHistory.store.load() ?? []
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
    func reconcileDanglingRecordings() -> Int {
        var count = 0
        for index in entries.indices where entries[index].status == .recording {
            entries[index].status = .error
            count += 1
        }
        if count > 0 {
            RecordingHistory.store.scheduleSave(entries)
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
        entries.insert(entry, at: 0)
        RecordingHistory.store.scheduleSave(entries)
        return entry.id
    }

    func markFinished(id: UUID, filePath: String) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].filePath = filePath
        entries[index].status = .saved
        entries[index].callDuration = Date().timeIntervalSince(entries[index].startedAt)
        RecordingHistory.store.scheduleSave(entries)
    }

    func markFailed(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].status = .error
        RecordingHistory.store.scheduleSave(entries)
    }

    /// Forces any pending debounced save to happen immediately — call
    /// before process exit, same reasoning as AppSettings.flush().
    func flush() {
        RecordingHistory.store.saveNow(entries)
    }
}
