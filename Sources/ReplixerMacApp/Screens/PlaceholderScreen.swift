import SwiftUI

/// Shared "not built yet" body for Phase 7.2's stub screens — each real
/// screen (7.3 Settings, 7.4 Recordings, 7.5 Home, 7.6 Profile) replaces its
/// own `PlaceholderScreen(...)` call with real content one sub-phase at a
/// time; `MissedCallsView` stays on this placeholder past Phase 7 (its
/// backend doesn't exist until Phase 10).
struct PlaceholderScreen: View {
    let title: String
    let systemImage: String

    var body: some View {
        ContentUnavailableView(
            title,
            systemImage: systemImage,
            description: Text("Ще не реалізовано.")
        )
    }
}
