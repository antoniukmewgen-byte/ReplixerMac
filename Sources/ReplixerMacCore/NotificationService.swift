import Foundation

/// Windows parity: `Services/NotificationService.cs` — a global, call-from-
/// anywhere toast entry point. Windows' version is a bare static C# event
/// (`Action<string, NotificationType>? Raised`) with `NotificationsViewModel`
/// as its one subscriber; here `ToastStore` plays that subscriber role
/// directly (both live in this module), so there's no separate event/
/// subscriber indirection to set up — `showSuccess`/`showError` write
/// straight into `ToastStore`.
///
/// `IsNotificationsEnabled` gating (Windows: `NotificationsViewModel
/// .OnRaised`'s `if (!_settings.IsNotificationsEnabled) return;`) lives here
/// rather than in `ToastStore`, so a disabled toggle is a zero-cost no-op at
/// every one of this type's call sites rather than a suppressed-but-still-
/// tracked toast.
public enum NotificationService {
    public static func showSuccess(_ message: String) {
        guard AppSettings.shared.isNotificationsEnabled else { return }
        ToastStore.shared.push(message: message, kind: .success)
    }

    public static func showError(_ message: String) {
        guard AppSettings.shared.isNotificationsEnabled else { return }
        ToastStore.shared.push(message: message, kind: .error)
    }
}
