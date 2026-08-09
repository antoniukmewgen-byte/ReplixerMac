import SwiftUI

/// Phase 7.2 placeholder. Windows parity source: `ProfileViewModel` (486
/// lines — integration test-connection forms, Telegram phone-auth flow via
/// a modal input dialog, ClearAllData). Real content (Drive/Telegram
/// sections only) lands in Phase 7.6; Kommo/Sheets sections stay stubbed
/// pending Phase 10 backends.
struct ProfileView: View {
    var body: some View {
        PlaceholderScreen(title: "Профіль", systemImage: "person.crop.circle")
    }
}

#Preview {
    ProfileView()
}
