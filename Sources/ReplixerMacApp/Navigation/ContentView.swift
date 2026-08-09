import SwiftUI

/// Root navigation shell — macOS-standard `NavigationSplitView` sidebar,
/// replacing Windows' single `ContentControl` bound to
/// `MainViewModel.CurrentViewModel`. `NavigationSplitView` itself owns the
/// sidebar's show/hide toolbar button and column-resize behavior — no
/// custom collapse logic needed, unlike Windows' tray/main-window handling.
struct ContentView: View {
    // Starts on .home, matching Windows always starting on HomeViewModel.
    @State private var selection: AppScreen? = .home

    var body: some View {
        NavigationSplitView {
            List(AppScreen.allCases, selection: $selection) { screen in
                Label(screen.title, systemImage: screen.systemImage)
                    .tag(screen)
            }
            .navigationTitle("ReplixerMac")
        } detail: {
            // Falls back to .home rather than a blank pane if selection
            // somehow goes nil (e.g. Cmd-click deselecting the sidebar row)
            // — AppScreen itself intentionally has no "none" case.
            screen(for: selection ?? .home)
        }
    }

    @ViewBuilder
    private func screen(for screen: AppScreen) -> some View {
        switch screen {
        case .home:
            HomeView()
        case .recordings:
            RecordingsView()
        case .missedCalls:
            MissedCallsView()
        case .settings:
            SettingsView()
        case .profile:
            ProfileView()
        }
    }
}

#Preview {
    ContentView()
}
