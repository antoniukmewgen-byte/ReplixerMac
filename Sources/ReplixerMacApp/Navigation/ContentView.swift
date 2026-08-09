import SwiftUI
import ReplixerMacCore

/// Root navigation shell — macOS-standard `NavigationSplitView` sidebar,
/// replacing Windows' single `ContentControl` bound to
/// `MainViewModel.CurrentViewModel`. `NavigationSplitView` itself owns the
/// sidebar's show/hide toolbar button and column-resize behavior — no
/// custom collapse logic needed, unlike Windows' tray/main-window handling.
struct ContentView: View {
    // Starts on .home, matching Windows always starting on HomeViewModel.
    @State private var selection: AppScreen? = .home

    // Phase 7.7: seeded once from AppSettings at view creation, not
    // recomputed per-render — the sheet's own `onFinish` callback is what
    // flips this back to false, so there's no need for this to track
    // AppSettings live (nothing else in this process changes
    // isSetupComplete out from under a running window).
    @State private var showingSetupWizard = !AppSettings.shared.isSetupComplete

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
        // .sheet (not a full-screen cover) — matches Windows' SetupWindow
        // being a separate modal window over MainWindow, not a takeover of
        // the whole app chrome. interactiveDismissDisabled so it can't be
        // swiped/Esc-dismissed without going through finish() (which is
        // what actually persists managerName + isSetupComplete).
        .sheet(isPresented: $showingSetupWizard) {
            SetupWizardView(onFinish: { showingSetupWizard = false })
                .interactiveDismissDisabled()
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
