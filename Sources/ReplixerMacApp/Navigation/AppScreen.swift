import Foundation
import SwiftUI

/// The top-level sections of ReplixerMac's sidebar navigation — macOS-native
/// counterpart to Windows' `MainViewModel.CurrentViewModel` switch (Home /
/// Recordings / MissedCalls / Settings / Profile), but driven by
/// `NavigationSplitView`'s standard sidebar-selection binding instead of a
/// hand-rolled router/`ContentControl`, per the user's explicit preference
/// (Phase 7.2) to follow macOS platform conventions rather than port
/// Windows' navigation shape 1:1.
///
/// `missedCalls` stays in the sidebar (matching Windows) even though its
/// backend (Kommo/Sheets delivery) doesn't exist on macOS yet — Phase 7
/// scope is UI-only for that screen until Phase 10 builds the backend; see
/// `MissedCallsView`'s placeholder doc comment.
enum AppScreen: String, CaseIterable, Identifiable, Hashable {
    case home
    case recordings
    case missedCalls
    case settings
    case profile

    var id: String { rawValue }

    /// Sidebar row label. Ukrainian, matching the rest of this app's
    /// user-facing/log strings.
    var title: String {
        switch self {
        case .home: return "Головна"
        case .recordings: return "Записи"
        case .missedCalls: return "Пропущені дзвінки"
        case .settings: return "Налаштування"
        case .profile: return "Профіль"
        }
    }

    /// SF Symbol for the sidebar row — chosen to be recognizable at a
    /// glance, not a strict port of Windows' icon set (which used
    /// different, WPF-specific glyph resources).
    var systemImage: String {
        switch self {
        case .home: return "house.fill"
        case .recordings: return "waveform"
        case .missedCalls: return "phone.down.fill"
        case .settings: return "gearshape.fill"
        case .profile: return "person.crop.circle.fill"
        }
    }

    /// Per-row accent behind `systemImage` in the sidebar's colorful icon
    /// badges (see `Theme.IconBadge`) — Mail/Reminders-style "each section
    /// gets its own color" convention, not tied to any status meaning
    /// elsewhere in the app (unlike `Theme.Status`'s semantic colors).
    var tintColor: Color {
        switch self {
        case .home: return .accentColor
        case .recordings: return .purple
        case .missedCalls: return .orange
        case .settings: return .gray
        case .profile: return .teal
        }
    }
}
