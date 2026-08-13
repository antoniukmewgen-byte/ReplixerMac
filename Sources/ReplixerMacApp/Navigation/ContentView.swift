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

    // Phase 11.3 fix: report and confirm used to be two *independent*
    // `.sheet(item:)` modifiers, each mirroring its own store's `pending`
    // into its own @State. That's exactly the setup SwiftUI's "Currently,
    // only presenting a single sheet is supported" runtime warning targets
    // — when `CallReportRequestStore.interrupt()` clears `pendingReport`
    // and the very next line (`CallConfirmRequestStore.requestConfirmation`)
    // sets `pendingConfirm`, both @State writes land close enough together
    // (both hopping over from a background Task via `receive(on: .main)`)
    // that SwiftUI sees two competing sheet-presentation requests instead
    // of one clean "dismiss, then present" handoff — the confirm sheet
    // then silently never appears, `requestConfirmation` hangs forever
    // awaiting a click nobody can make, and the interrupted call never
    // even reaches `markDraft` because the whole chain is stuck upstream
    // of it.
    //
    // Fix: a single `@State` driving a single `.sheet(item:)`, presenting
    // one of two cases. Switching an *existing* `.sheet(item:)`'s item to a
    // different identity is the officially-supported "swap sheet content"
    // path — SwiftUI itself sequences the dismiss-then-present handoff,
    // rather than two independent sheet lifecycles racing each other.
    private enum ActiveCallSheet: Identifiable {
        case report(CallReportRequestStore.PendingRequest)
        case confirm(CallConfirmRequestStore.PendingRequest)

        var id: UUID {
            switch self {
            case .report(let request): return request.id
            case .confirm(let request): return request.id
            }
        }
    }

    // Report takes priority if (in principle) both stores somehow had a
    // pending request at the same instant — matches the real-world
    // sequencing (`interrupt()` always clears the report *before* a new
    // confirm request is even created), so this is a defensive tie-break,
    // not something expected to actually matter in practice.
    @State private var activeCallSheet: ActiveCallSheet?

    private func refreshActiveCallSheet() {
        if let report = CallReportRequestStore.shared.pending {
            activeCallSheet = .report(report)
        } else if let confirm = CallConfirmRequestStore.shared.pending {
            activeCallSheet = .confirm(confirm)
        } else {
            activeCallSheet = nil
        }
    }

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

    private let confirmDidChangePublisher = NotificationCenter.default
        .publisher(for: CallConfirmRequestStore.didChangeNotification)
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
        // Phase 10.0/11.1, unified Phase 11.3 (see `ActiveCallSheet`'s doc
        // comment above for why this used to be two separate `.sheet(item:)`
        // modifiers and no longer is): presents either the blocking
        // call-report form — CallRecordingCoordinator is off somewhere
        // suspended in `withCheckedContinuation` waiting for CallReportView's
        // submit button to call `CallReportRequestStore.shared.submit(_:)`
        // (or for `interrupt()` to resolve it instead) — or the "record this
        // call?"/"stop recording?" confirm dialog. Both still
        // `interactiveDismissDisabled()` for the same reason as the setup
        // wizard — Windows has no "close without answering" affordance for
        // either.
        //
        // Report's height is pinned to the live window size (minus margin,
        // see `reportSheetHeight`'s doc comment); confirm stays a small
        // fixed-size card since it has no form content to grow into.
        .sheet(item: $activeCallSheet) { sheet in
            switch sheet {
            case .report(let request):
                CallReportView(platform: request.platform, duration: request.duration, existing: request.existing)
                    .frame(width: 500, height: reportSheetHeight)
                    .interactiveDismissDisabled()
            case .confirm(let request):
                CallConfirmView(
                    kind: request.kind,
                    platform: request.platform,
                    recordingStartedAt: request.recordingStartedAt
                )
                .frame(width: 360)
                .interactiveDismissDisabled()
            }
        }
        .onReceive(reportDidChangePublisher) { _ in
            refreshActiveCallSheet()
        }
        .onReceive(confirmDidChangePublisher) { _ in
            refreshActiveCallSheet()
        }
        .onAppear {
            refreshActiveCallSheet()
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
