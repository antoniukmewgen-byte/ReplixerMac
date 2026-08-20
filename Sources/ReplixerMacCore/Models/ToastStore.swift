import Foundation

/// Thread-safe, live snapshot of the active toast stack — same "lock-
/// protected array + didChange notification" shape as `RecordingStatusStore`,
/// generalized from a single value to an array since multiple toasts can be
/// alive at once (Windows parity: `NotificationsViewModel.Items`, an
/// `ObservableCollection<NotificationItem>`).
///
/// Auto-removal (Windows parity: `NotificationsViewModel.Show`'s
/// `DispatcherTimer` that flips `IsLeaving` after `total - LeaveSeconds`)
/// is simplified here to a single scheduled removal per toast rather than a
/// two-phase "start leaving, then actually remove once the exit animation
/// finishes" handshake — SwiftUI's own `.transition`/`withAnimation` on the
/// array mutation already plays an exit animation when an item disappears
/// from a `ForEach`, so there's no separate "leaving" state to track here;
/// `ToastView` (ReplixerMacApp) owns the animation, this type only owns the
/// timing of *when* an item disappears from the array.
public final class ToastStore {
    public static let shared = ToastStore()

    public static let didChangeNotification = Notification.Name("ReplixerMac.ToastStore.didChange")

    public enum Kind: Sendable {
        case success
        case error
    }

    public struct Toast: Identifiable, Sendable {
        public let id = UUID()
        public let message: String
        public let kind: Kind
    }

    // Windows parity: NotificationsViewModel's SuccessSeconds/ErrorSeconds
    // constants (3.0/5.0) — how long a toast stays on screen before it's
    // removed.
    private static let successSeconds: UInt64 = 3
    private static let errorSeconds: UInt64 = 5

    private let lock = NSLock()
    private var _items: [Toast] = []

    public var items: [Toast] {
        lock.lock()
        defer { lock.unlock() }
        return _items
    }

    private init() {}

    /// Not `public` — only `NotificationService` (same module) should ever
    /// push a new toast, same "single writer, everyone else reads via
    /// `items`/`didChangeNotification`" rule `RecordingStatusStore.update`
    /// follows.
    func push(message: String, kind: Kind) {
        let toast = Toast(message: message, kind: kind)
        lock.lock()
        _items.append(toast)
        lock.unlock()
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)

        let seconds = kind == .success ? Self.successSeconds : Self.errorSeconds
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            self?.remove(toast.id)
        }
    }

    private func remove(_ id: UUID) {
        lock.lock()
        let removed = _items.contains { $0.id == id }
        _items.removeAll { $0.id == id }
        lock.unlock()
        guard removed else { return }
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
