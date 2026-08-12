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

    // Phase 10.0: mirrors CallReportRequestStore.shared.pending, same
    // headless-core-can't-be-ObservedObject reasoning as RecordingsView's
    // `entries`/RecordingHistory.didChangeNotification pair — except this
    // one drives `.sheet(item:)` instead of a list refresh, since
    // `PendingRequest` carries the identity SwiftUI needs to know which
    // request (if any) to present.
    @State private var pendingReport: CallReportRequestStore.PendingRequest?

    // Tracks the window's actual content size so the call-report sheet
    // below can be sized *relative to it* (height = window height minus a
    // fixed margin) instead of a hardcoded constant — the window itself is
    // freely resizable (no .windowResizability(.contentSize) lock), so a
    // fixed sheet height risks the same "sheet taller than the window"
    // overflow this whole area of the app has already hit once. Sizing off
    // the live window height instead means the sheet can never exceed the
    // window no matter how the user has resized it.
    @State private var windowContentSize: CGSize = .zero
    // Inset from the window's top/bottom edges, matching what "margin"
    // means visually — the sheet's card floats inside the window with this
    // much breathing room on either side rather than touching its edges.
    private static let reportSheetVerticalMargin: CGFloat = 40
    // Floor so an unusually small window doesn't collapse the form to an
    // unusable sliver before GeometryReader has reported a real size yet
    // (windowContentSize starts at .zero on first render).
    private static let reportSheetMinHeight: CGFloat = 400

    private var reportSheetHeight: CGFloat {
        max(Self.reportSheetMinHeight, windowContentSize.height - Self.reportSheetVerticalMargin * 2)
    }

    private let reportDidChangePublisher = NotificationCenter.default
        .publisher(for: CallReportRequestStore.didChangeNotification)
        .receive(on: DispatchQueue.main)

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
        // Invisible size probe, not a visible background — reads this
        // view's own laid-out size (== the window's content size) on every
        // layout pass so `reportSheetHeight` above always reflects the
        // window's *current* size, live, including manual resizes while a
        // sheet happens to be open.
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { windowContentSize = proxy.size }
                    .onChange(of: proxy.size) { _, newSize in windowContentSize = newSize }
            }
        )
        // .sheet (not a full-screen cover) — matches Windows' SetupWindow
        // being a separate modal window over MainWindow, not a takeover of
        // the whole app chrome. interactiveDismissDisabled so it can't be
        // swiped/Esc-dismissed without going through finish() (which is
        // what actually persists managerName + isSetupComplete).
        .sheet(isPresented: $showingSetupWizard) {
            SetupWizardView(onFinish: { showingSetupWizard = false })
                .interactiveDismissDisabled()
        }
        // Phase 10.0: the blocking call-report form — CallRecordingCoordinator
        // is off somewhere suspended in `withCheckedContinuation` waiting for
        // CallReportView's submit button to call
        // `CallReportRequestStore.shared.submit(_:)`, which clears `pending`
        // and (via the notification below) dismisses this sheet on its own.
        // interactiveDismissDisabled for the same reason as the setup wizard
        // — Windows has no "close without reporting" affordance here either.
        //
        // Height pinned to the live window size (minus margin) rather than
        // CallReportView's own default — see reportSheetHeight's doc
        // comment. Width stays fixed (matches Windows' Views/Dialogs/
        // CallReportView.xaml Width="500" card) since only height was
        // called out as needing to track the window.
        .sheet(item: $pendingReport) { request in
            CallReportView(platform: request.platform, duration: request.duration)
                .frame(width: 500, height: reportSheetHeight)
                .interactiveDismissDisabled()
        }
        .onReceive(reportDidChangePublisher) { _ in
            pendingReport = CallReportRequestStore.shared.pending
        }
        .onAppear {
            pendingReport = CallReportRequestStore.shared.pending
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
