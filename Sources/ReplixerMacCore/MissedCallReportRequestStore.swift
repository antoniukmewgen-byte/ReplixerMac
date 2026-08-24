import Foundation

/// Bridges the "Не додзвонився" button (`HomeView`) to the missed-call
/// report sheet (`ContentView`'s own independent `.sheet(item:)` — see that
/// file's doc comment on why this isn't folded into `ActiveCallSheet`).
///
/// Unlike `CallReportRequestStore`, this is **not** a continuation-based
/// suspend-the-caller bridge — there's no `CallRecordingCoordinator`-side
/// actor awaiting an answer the way a just-ended recording awaits its
/// report. A missed-call report is manager-initiated from a cold start (no
/// call/recording preceding it), so `open()` just publishes "show the
/// form" and `submit(_:)` hands the finished data straight to
/// `MissedCallHistory`/`MissedCallDeliveryService` — same "history entry
/// exists immediately, delivery catches up asynchronously" ordering as
/// `RecordingHistory.addStarted`/`UploadOrchestrator`, see those doc
/// comments. No Windows parity source for this particular type (Windows'
/// `HomeViewModel.MissedCallCommand` opens `MissedCallReportView` as a
/// plain WPF dialog inline, no separate request-store indirection needed
/// there since Windows has no SwiftUI-style "sheet driven by a different
/// module" split to bridge).
public final class MissedCallReportRequestStore {
    public static let shared = MissedCallReportRequestStore()

    public static let didChangeNotification = Notification.Name("ReplixerMac.MissedCallReportRequestStore.didChange")

    public struct PendingRequest: Equatable, Identifiable {
        // Same "fresh id purely for SwiftUI's Identifiable, not a real
        // identity concept" reasoning as CallReportRequestStore.PendingRequest
        // — only ever one alive at a time.
        public let id = UUID()
        /// The moment "Не додзвонився" was clicked — Windows parity:
        /// `MissedCallReportViewModel`'s constructor-injected `missedAt`
        /// (there, `DateTime.Now` read by `HomeViewModel.MissedCallCommand`
        /// at the same click). Feeds `MissedCallReportView`'s default/
        /// fallback first-contact time.
        public let missedAt: Date

        public static func == (lhs: PendingRequest, rhs: PendingRequest) -> Bool {
            lhs.id == rhs.id
        }
    }

    private let lock = NSLock()
    private var _pending: PendingRequest?

    /// Thread-safe snapshot — mirrored into @State by `ContentView`, same
    /// pattern as `CallReportRequestStore.pending`.
    public var pending: PendingRequest? {
        lock.lock()
        defer { lock.unlock() }
        return _pending
    }

    private init() {}

    /// Called by `HomeView`'s "Не додзвонився" button — opens a fresh, blank
    /// form. A no-op (doesn't clobber) if a request is already pending,
    /// same "only one at a time" invariant `CallReportRequestStore` has,
    /// just enforced by ignoring the second call instead of interrupting
    /// the first (there's no equivalent of a new incoming call that should
    /// force this one closed).
    public func open() {
        lock.lock()
        guard _pending == nil else {
            lock.unlock()
            return
        }
        _pending = PendingRequest(missedAt: Date())
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// Called by `MissedCallReportView` when the user submits the form —
    /// records it in `MissedCallHistory` (permanent record) and hands it to
    /// `MissedCallDeliveryService` (Kommo delivery queue) before closing
    /// the sheet.
    public func submit(_ data: MissedCallReportData) {
        lock.lock()
        _pending = nil
        lock.unlock()
        let id = MissedCallHistory.shared.add(data)
        MissedCallDeliveryService.shared.submit(id: id, data: data)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// Called by `MissedCallReportView`'s close (X) button when the manager
    /// dismisses the form without submitting — a deliberate mac-only
    /// departure from Windows (which has no "close without reporting"
    /// affordance on this dialog at all, see that view's doc comment).
    /// Unlike `CallReportRequestStore.interrupt()`, there's nothing to
    /// preserve as a resumable draft here: a missed-call report isn't backed
    /// by any in-progress recording/history entry until `submit(_:)` writes
    /// one, so closing just discards whatever was typed and clears the
    /// pending request.
    public func close() {
        lock.lock()
        _pending = nil
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
