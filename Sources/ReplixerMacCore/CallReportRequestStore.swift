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
/// Phase 11.3 — draft/interrupt recovery (Windows' `CaptureDraft`/
/// `RecordingStatus.Draft`, source: `HomeViewModel.ShowDialog` calling
/// `DismissCallReport(interrupted: true)` before showing any new
/// start/end confirm dialog). A second call arriving while a report is
/// still pending no longer needs to be dropped by `callStarted`'s
/// `isRecording` guard — `CallRecordingCoordinator.finishRecording` now
/// resets `isRecording` *before* awaiting `requestReport` (see its doc
/// comment), so the new call proceeds normally, and whoever is about to
/// show it a confirm dialog (`ReplixerMacApp`'s `AppDelegate`) calls
/// `interrupt()` here first — mirroring `ShowDialog` unconditionally
/// dismissing any open report. Since mac's `CallReportView` is a plain
/// `@State`-in-View (no persistent ViewModel object `interrupt()` could
/// call a `CaptureDraft()`-style method on from outside SwiftUI), the view
/// instead keeps `liveDraft` continuously up to date itself via
/// `updateLiveDraft(_:)` on every field change — `interrupt()` just reads
/// whatever was last pushed.
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
        /// Phase 11.3 — prefills the form when resuming a previously
        /// interrupted draft (Windows parity: `CallReportViewModel`'s
        /// `existing:` constructor param). `nil` for a normal post-call
        /// report request.
        public let existing: CallReportData?

        public static func == (lhs: PendingRequest, rhs: PendingRequest) -> Bool {
            lhs.id == rhs.id
        }
    }

    /// Phase 11.3 — how a report request resolved: the user actually
    /// submitted the form, or a new call interrupted it first. Windows
    /// parity: `StopRecordingAsync` branching on `_reportInterrupted`.
    public enum Outcome: Sendable {
        case submitted(CallReportData)
        case interrupted(draft: CallReportData?)
    }

    private let lock = NSLock()
    private var _pending: PendingRequest?
    private var continuation: CheckedContinuation<Outcome, Never>?
    // Phase 11.3: live snapshot of whatever the currently-open CallReportView
    // has captured so far, pushed by the view itself on every field change
    // (see `updateLiveDraft(_:)`) — `interrupt()` reads this instead of
    // reaching into a ViewModel the way Windows' `CaptureDraft()` does.
    private var liveDraft: CallReportData?

    /// Thread-safe snapshot — mirrored into @State by the SwiftUI layer on
    /// `didChangeNotification`, same as `RecordingStatusStore.current`.
    public var pending: PendingRequest? {
        lock.lock()
        defer { lock.unlock() }
        return _pending
    }

    private init() {}

    /// Called by `CallRecordingCoordinator` off the main actor — suspends
    /// until `submit(_:)` (user finished the form) or `interrupt()` (a new
    /// call bumped it) resolves it. Only one request can be pending at a
    /// time — a second call here before the first resolves would silently
    /// drop the first continuation; `CallRecordingCoordinator` guards
    /// `resumeDraft` against this (`pending == nil` check) but a genuinely
    /// simultaneous auto-detected call-end report can still in principle
    /// race it, same accepted-gap standard as `CallConfirmRequestStore
    /// .requestConfirmation`'s doc comment.
    ///
    /// - Parameter existing: non-nil when resuming a `.draft` entry —
    ///   prefills the form instead of starting blank (Windows parity:
    ///   `RequestCallReportAsync(existing: entry.ReportData)`).
    func requestReport(platform: String, duration: TimeInterval, existing: CallReportData? = nil) async -> Outcome {
        await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            lock.lock()
            _pending = PendingRequest(platform: platform, duration: duration, existing: existing)
            self.continuation = continuation
            liveDraft = existing
            lock.unlock()
            NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
        }
    }

    /// Called by `CallReportView` when the user actually submits the form.
    /// No more "cancel/dismiss with nil" path (the form still has no cancel
    /// button, same as before Phase 11.3) — an externally-triggered
    /// dismissal now always goes through `interrupt()` instead, which is
    /// the only other way a pending request resolves.
    public func submit(_ data: CallReportData) {
        lock.lock()
        let resumingContinuation = continuation
        continuation = nil
        _pending = nil
        liveDraft = nil
        lock.unlock()
        resumingContinuation?.resume(returning: .submitted(data))
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// Phase 11.3 — called externally (`ReplixerMacApp`'s `AppDelegate`,
    /// right before showing a new start/end confirm dialog) when a report
    /// form might still be open for an earlier call. Windows parity:
    /// `ShowDialog`'s unconditional `DismissCallReport(interrupted: true)`.
    /// A no-op if nothing is actually pending (the common case — most new
    /// calls arrive with no report form open at all).
    public func interrupt() {
        lock.lock()
        guard let resumingContinuation = continuation else {
            lock.unlock()
            return
        }
        let draft = liveDraft
        continuation = nil
        _pending = nil
        liveDraft = nil
        lock.unlock()
        resumingContinuation.resume(returning: .interrupted(draft: draft))
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// Phase 11.3 — called by `CallReportView` (a different module,
    /// ReplixerMacApp — same reasoning as `submit`/`interrupt` needing to be
    /// `public`) on every field change so `interrupt()` always has an
    /// up-to-date snapshot to hand back, even though it's invoked from
    /// outside SwiftUI with no direct read access to the view's `@State`.
    public func updateLiveDraft(_ data: CallReportData) {
        lock.lock()
        defer { lock.unlock() }
        liveDraft = data
    }
}
