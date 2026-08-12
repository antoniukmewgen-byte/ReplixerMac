import Foundation

/// Bridges `CallRecordingCoordinator` (headless actor, ReplixerMacCore) to
/// the SwiftUI report-form sheet (ReplixerMacApp) — the async counterpart
/// of `RecordingStatusStore`'s one-way "mirror state into a plain
/// NotificationCenter-observable snapshot" pattern, except this direction
/// also needs an *answer* back, not just a status mirror.
///
/// Windows parity source: `HomeViewModel.RequestCallReportAsync`'s
/// `TaskCompletionSource<CallReportData?>` — same "suspend the caller until
/// the dialog reports back" shape, just expressed with Swift concurrency
/// (`withCheckedContinuation`) instead of a TCS, and with the dialog itself
/// living in a different module (Phase 7's headless/SwiftUI-free core
/// split) rather than the same MVVM layer.
///
/// No draft/interrupt recovery (Windows' `CaptureDraft`/`RecordingStatus
/// .Draft`) — mac's `RecordingStatus` deliberately has no `.draft` case
/// (see `RecordingsView`'s doc comment), so a second call arriving while a
/// report is still pending is simply dropped by
/// `CallRecordingCoordinator.callStarted`'s existing `isRecording` guard,
/// same as every other "already busy" case there.
public final class CallReportRequestStore {
    public static let shared = CallReportRequestStore()

    public static let didChangeNotification = Notification.Name("ReplixerMac.CallReportRequestStore.didChange")

    public struct PendingRequest: Equatable, Identifiable {
        // Only ever one PendingRequest alive at a time (see requestReport's
        // doc comment) — a fresh id per request is just so ReplixerMacApp
        // can drive `.sheet(item:)` off this type directly, Identifiable
        // conformance being SwiftUI's requirement, not a real identity
        // concept here.
        public let id = UUID()
        public let platform: String
        public let duration: TimeInterval

        public static func == (lhs: PendingRequest, rhs: PendingRequest) -> Bool {
            lhs.id == rhs.id
        }
    }

    private let lock = NSLock()
    private var _pending: PendingRequest?
    private var continuation: CheckedContinuation<CallReportData?, Never>?

    /// Thread-safe snapshot — mirrored into @State by the SwiftUI layer on
    /// `didChangeNotification`, same as `RecordingStatusStore.current`.
    public var pending: PendingRequest? {
        lock.lock()
        defer { lock.unlock() }
        return _pending
    }

    private init() {}

    /// Called by `CallRecordingCoordinator` off the main actor — suspends
    /// until `submit(_:)` is called from the report sheet on the main
    /// thread. Only one request can be pending at a time (coordinator only
    /// ever awaits one at once, same single-active-call assumption as the
    /// rest of the pipeline), so a second call here before the first
    /// resolves would silently drop the first continuation — not a
    /// concern in practice since CallRecordingCoordinator never calls this
    /// twice concurrently.
    func requestReport(platform: String, duration: TimeInterval) async -> CallReportData? {
        await withCheckedContinuation { (continuation: CheckedContinuation<CallReportData?, Never>) in
            lock.lock()
            _pending = PendingRequest(platform: platform, duration: duration)
            self.continuation = continuation
            lock.unlock()
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    /// Called by `CallReportView` on submit (with the filled-in data) or on
    /// cancel/dismiss (with `nil`, matching Windows' "dismissed externally"
    /// path in `DismissCallReport`) — resolves the waiting coordinator
    /// either way so `finishRecording()` never hangs.
    public func submit(_ data: CallReportData?) {
        lock.lock()
        let resumingContinuation = continuation
        continuation = nil
        _pending = nil
        lock.unlock()
        resumingContinuation?.resume(returning: data)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
