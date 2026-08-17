import Foundation

/// Phase 11.1 — bridges `CallMonitor`'s auto-detected start/end events to a
/// SwiftUI confirm dialog, the same continuation-based shape as
/// `CallReportRequestStore` ("suspend the caller until the dialog answers").
/// Windows parity source: `HomeViewModel.OnCallDetected`/`OnCallEnded`
/// showing a `CallDialogViewModel` before either starting or stopping the
/// recorder — mac's pipeline previously wired `CallMonitor` straight into
/// `CallRecordingCoordinator` with no human in the loop at all (see
/// `HomeView`'s now-stale "fully automatic" doc comment), which is exactly
/// the gap the user flagged ("погодження або відхилення запису").
///
/// Unlike `CallReportRequestStore` (called from `CallRecordingCoordinator`
/// itself, same module), this store's `requestConfirmation` is called from
/// `ReplixerMacApp`'s `AppDelegate` — a different module/target — so it has
/// to be `public`, not just internal.
public final class CallConfirmRequestStore {
    public static let shared = CallConfirmRequestStore()

    public static let didChangeNotification = Notification.Name("ReplixerMac.CallConfirmRequestStore.didChange")

    /// Windows parity: `CallDialogViewModel`'s two shapes — `OnCallDetected`
    /// (`recordingStartedAt: null`) vs `OnCallEnded` (`recordingStartedAt`
    /// set), which there drives both the primary/secondary button labels and
    /// whether the "are you sure you want to cancel" double-confirm applies
    /// to the secondary button. Encoded here as a case rather than reusing
    /// `RecordingStatusStore`'s optional-Date shape, since the two kinds also
    /// need different button copy that's easier to keep straight as a switch
    /// in the view than as ad hoc boolean flags.
    public enum Kind: Equatable, Sendable {
        case start
        case end
    }

    public struct PendingRequest: Equatable, Identifiable {
        // Same "fresh id per request purely for SwiftUI's .sheet(item:)"
        // reasoning as CallReportRequestStore.PendingRequest.
        public let id = UUID()
        public let kind: Kind
        public let platform: String
        /// Only set for `.end` — drives the live elapsed-duration readout in
        /// the dialog, Windows parity: `CallDialogViewModel`'s
        /// `recordingStartedAt`-driven `DispatcherTimer`.
        public let recordingStartedAt: Date?

        public static func == (lhs: PendingRequest, rhs: PendingRequest) -> Bool {
            lhs.id == rhs.id
        }
    }

    private let lock = NSLock()
    private var _pending: PendingRequest?
    private var continuation: CheckedContinuation<Bool, Never>?

    /// Thread-safe snapshot — mirrored into @State by the SwiftUI layer on
    /// `didChangeNotification`, same as `CallReportRequestStore.pending`.
    public var pending: PendingRequest? {
        lock.lock()
        defer { lock.unlock() }
        return _pending
    }

    private init() {}

    /// Called from `AppDelegate`'s `CallMonitor.onCallStarted`/`onCallEnded`
    /// closures — suspends until `submit(_:)` is called from the dialog.
    /// Only one request can be pending at a time, same single-active-call
    /// assumption as `CallReportRequestStore.requestReport`: a second call
    /// here before the first resolves would silently orphan the first
    /// continuation (it never resumes).
    ///
    /// The "a call could end while the 'start recording?' dialog is still
    /// up" case this comment used to flag as an accepted gap is now closed —
    /// `AppDelegate`'s `monitor.onCallEnded` closure calls `submit(false)`
    /// itself (Windows parity: `HomeViewModel.OnCallEnded`'s
    /// `if (!_isRecording) { DismissDialog(); return; }`) whenever it fires
    /// while nothing is recording yet, which is exactly the signal that the
    /// still-open `.start` dialog's call has already gone away.
    public func requestConfirmation(kind: Kind, platform: String, recordingStartedAt: Date? = nil) async -> Bool {
        await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            lock.lock()
            _pending = PendingRequest(kind: kind, platform: platform, recordingStartedAt: recordingStartedAt)
            self.continuation = continuation
            lock.unlock()
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    /// Called by `CallConfirmView` when the user picks an action —
    /// `true` for "record"/"stop", `false` for "skip"/"continue recording".
    /// Also called with `false` by `AppDelegate`'s `monitor.onCallEnded`
    /// closure to auto-dismiss a stale `.start` dialog whose call already
    /// ended before the user answered — see `requestConfirmation`'s doc
    /// comment. Same resume path either way: whoever is awaiting
    /// `requestConfirmation` can't tell a real "Пропустити" tap apart from
    /// an auto-dismiss, which is exactly the desired effect (neither should
    /// start recording).
    public func submit(_ confirmed: Bool) {
        lock.lock()
        let resumingContinuation = continuation
        continuation = nil
        _pending = nil
        lock.unlock()
        resumingContinuation?.resume(returning: confirmed)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
