import Foundation

/// Generic debounced, atomic JSON persistence for a single Codable value —
/// shared by AppSettings (Phase 2.1) and, later, the recordings history
/// (Phase 2.2), so both get the same crash-safety guarantee without
/// duplicating the write logic.
///
/// Atomic: writes to a `.tmp` sibling first, then replaces the real path in
/// one filesystem operation (`FileManager.replaceItemAt`) — a crash or
/// power loss mid-write always leaves either the old file or the fully
/// written new one, never a truncated/corrupt one. Same pattern as
/// AudioMixerEncoder's `.inprogress` recording files (Phase 1.6), applied
/// here to settings/history JSON instead of audio.
///
/// Debounced: rapid successive changes (e.g. several settings edited in a
/// row) coalesce into a single disk write 500ms after the last change,
/// matching the interval Replixer's Windows `AppSettings.cs` uses.
public final class JSONStore<Value: Codable> {
    public let url: URL

    private let queue = DispatchQueue(label: "JSONStore")
    private var pendingWorkItem: DispatchWorkItem?
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    init(url: URL) {
        self.url = url
    }

    /// Synchronous load — fine to call at startup before anything else is
    /// running.
    ///
    /// Distinguishes "file doesn't exist yet" (`.notFound`, expected on
    /// first run — safe to bootstrap defaults and write them) from "file
    /// exists but failed to decode" (`.decodeFailed`, e.g. a hand-edit that
    /// broke the JSON — must NOT be treated the same as `.notFound`, since
    /// callers that bootstrap-and-save defaults on `.notFound` would
    /// otherwise silently overwrite/destroy an existing file's data just
    /// because one field had a typo).
    func load() -> LoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .notFound }
        do {
            let data = try Data(contentsOf: url)
            let value = try JSONDecoder().decode(Value.self, from: data)
            return .decoded(value)
        } catch {
            return .decodeFailed(error)
        }
    }

    enum LoadResult {
        case notFound
        case decoded(Value)
        case decodeFailed(Swift.Error)
    }

    /// Schedules a debounced write 500ms out; a call before that fires
    /// cancels and reschedules, so N rapid changes produce one write.
    func scheduleSave(_ value: Value) {
        pendingWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in self?.write(value) }
        pendingWorkItem = workItem
        queue.asyncAfter(deadline: .now() + 0.5, execute: workItem)
    }

    /// Writes immediately, bypassing the debounce — call before process
    /// exit so a change made right before shutdown isn't lost to a
    /// still-pending debounce timer that never gets to fire.
    func saveNow(_ value: Value) {
        pendingWorkItem?.cancel()
        pendingWorkItem = nil
        write(value)
    }

    private func write(_ value: Value) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try encoder.encode(value)
            let tempURL = url.appendingPathExtension("tmp")
            try data.write(to: tempURL)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL)
        } catch {
            print("[JSONStore] ⚠️ не вдалося зберегти \(url.lastPathComponent): \(error)")
            let fileName = url.lastPathComponent
            Task { await ErrorReporter.shared.report(category: "JSON_STORE", message: "Не вдалося зберегти \(fileName) на диск.", error: error) }
        }
    }
}
