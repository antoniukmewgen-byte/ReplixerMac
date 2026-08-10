import SwiftUI

/// Phase 7.2 placeholder — unlike the other stub screens, this one stays a
/// placeholder past Phase 7 too: Windows' `MissedCallsViewModel` (166
/// lines) depends on a Kommo/Sheets missed-call delivery backend that
/// doesn't exist on macOS yet (that's Phase 10 scope). Revisit once that
/// backend is built.
struct MissedCallsView: View {
    var body: some View {
        PlaceholderScreen(title: "Пропущені дзвінки", systemImage: "phone.down.fill")
    }
}
