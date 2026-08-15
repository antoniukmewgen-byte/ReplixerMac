import Foundation

/// Windows parity source: `Infrastructure/PositionPolicy.cs` — verbatim
/// logic port (three roles: "Менеджер"/"Діагност"/"Кваліфікатор"), per
/// explicit instruction to keep full role parity rather than simplifying to
/// a single mac role. Pure/stateless on purpose — CallReportView (Phase
/// 7-style plain-@State SwiftUI, ReplixerMacApp) and
/// CallRecordingCoordinator (headless, ReplixerMacCore) both call straight
/// into these static functions instead of duplicating the role→visibility
/// mapping in two places.
public enum PositionPolicy {
    public static func isTelegramVisible(_ position: String?) -> Bool {
        position != "Діагност"
    }

    public static func isCallTypeVisible(_ position: String?) -> Bool {
        position == "Менеджер"
    }

    public static func isLeadSourceVisible(_ position: String?) -> Bool {
        position != "Діагност"
    }

    public static func isRatingVisible(_ position: String?) -> Bool {
        position == "Менеджер"
    }

    public static func isOutcomeVisible(_ position: String?) -> Bool {
        position == "Менеджер"
    }

    /// Windows parity: different minimum call-duration thresholds per role
    /// before a finished recording's Telegram send is skipped entirely —
    /// Кваліфікатор's very short "quick call" role only needs 1 minute to
    /// count, Менеджер needs a real 10-minute conversation, and every other
    /// role (Діагност — see isTelegramVisible above) always skips.
    public static func shouldSkipTelegram(_ position: String?, duration: TimeInterval) -> Bool {
        switch position {
        case "Кваліфікатор":
            return duration < 60
        case "Менеджер":
            return duration < 600
        default:
            return true
        }
    }

    /// Windows parity: `ProfileViewModel.FilteredTelegramChats`/
    /// `SetupViewModel`'s identical inline duplicate of the same rule —
    /// centralized here instead of copy-pasted per screen. Кваліфікатор's
    /// quick-call role only ever reports into the one shared team chat;
    /// every other role sees every other chat, but never that one (it isn't
    /// a meaningful destination for a real per-manager call report).
    private static let qualifierOnlyChatName = "Чат Kvalifikatory Team"

    public static func filteredTelegramChats(_ chats: [TelegramChat], position: String?) -> [TelegramChat] {
        if position == "Кваліфікатор" {
            return chats.filter { $0.name == qualifierOnlyChatName }
        }
        return chats.filter { $0.name != qualifierOnlyChatName }
    }
}
