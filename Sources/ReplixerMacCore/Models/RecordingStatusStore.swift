import Foundation

/// Thread-safe, live snapshot of "is a call being recorded right now" —
/// mirrors `CallRecordingCoordinator`'s private actor-isolated `isRecording`
/// state so SwiftUI (Phase 7.5's HomeView, main thread) can read/observe it
/// without needing to `await` into the actor on every UI refresh (actor
/// method calls are async by nature; a plain `NSLock`-protected snapshot
/// isn't, so it's readable synchronously from `View.body`).
///
/// Written synchronously from inside `CallRecordingCoordinator`'s
/// actor-isolated methods (`callStarted`/`finishRecording`) — a plain
/// `NSLock`-based type has no `await` of its own, so calling into it from
/// actor-isolated code doesn't reintroduce any of the concurrency hazards
/// that isolation exists to prevent. Same "lock-protected snapshot +
/// didChange notification, mutation and notification never drift apart"
/// pattern as `RecordingHistory`.
///
/// No Windows-parity source: `HomeViewModel.IsRecording`/`CallContent` are
/// plain properties on the same object that owns the recording, updated
/// synchronously in-process — there's no cross-actor/cross-thread gap to
/// bridge on WPF's single-threaded UI+logic model the way there is here.
public final class RecordingStatusStore {
    public static let shared = RecordingStatusStore()

    public static let didChangeNotification = Notification.Name("ReplixerMac.RecordingStatusStore.didChange")

    public struct Status: Sendable {
        public let isRecording: Bool
        public let platform: String?
        public let startedAt: Date?

        public static let idle = Status(isRecording: false, platform: nil, startedAt: nil)
    }

    private let lock = NSLock()
    private var _status: Status = .idle

    public var status: Status {
        lock.lock()
        defer { lock.unlock() }
        return _status
    }

    private init() {}

    /// `internal`, not `public` — only `CallRecordingCoordinator` (same
    /// module) should ever push a new status; every other caller (the UI
    /// layer) only reads via `status`/`didChangeNotification`.
    func update(_ status: Status) {
        lock.lock()
        _status = status
        lock.unlock()
        NotificationCenter.default.post(name: RecordingStatusStore.didChangeNotification, object: nil)
    }
}
