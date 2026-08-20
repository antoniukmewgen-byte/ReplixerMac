import SwiftUI
import AppKit
import ReplixerMacCore

/// Root navigation shell — macOS-standard `NavigationSplitView` sidebar,
/// replacing Windows' single `ContentControl` bound to
/// `MainViewModel.CurrentViewModel`. `NavigationSplitView` itself owns the
/// sidebar's show/hide toolbar button and column-resize behavior — no
/// custom collapse logic needed, unlike Windows' tray/main-window handling.
struct ContentView: View {
    // Starts on .home, matching Windows always starting on HomeViewModel.
    @State private var selection: AppScreen? = .home

    // Design-only addition (no behavior change): mirrors
    // RecordingStatusStore.shared.status.isRecording so the sidebar's Home
    // row can show a small live pulsing dot next to its icon — same "local
    // @State mirror refreshed via NotificationCenter" pattern HomeView
    // already uses for the same store.
    @State private var isRecording = RecordingStatusStore.shared.status.isRecording
    private let sidebarStatusPublisher = NotificationCenter.default
        .publisher(for: RecordingStatusStore.didChangeNotification)
        .receive(on: DispatchQueue.main)

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
    // Phase 11.5: folded `MissedCallReportRequestStore`'s pending request in
    // as a third case rather than keeping it as its own independent
    // `.sheet(item:)` — an earlier version did that, reasoning that a
    // missed-call report has no continuation to orphan the way
    // report/confirm do, so a lost presentation would just be a harmless
    // ordering glitch. That reasoning covered the *hang* risk but not the
    // presentation itself: two independent `.sheet(item:)` modifiers on one
    // view is exactly the setup that caused the original Phase 11.3 bug
    // (SwiftUI silently drops the second one when both items go non-nil
    // close together), and `missedCallButton` (`HomeView`) is deliberately
    // clickable even while a call is actively recording — so "manager opens
    // 'Не додзвонився' right as the just-ended call's report/confirm sheet
    // is about to appear" is a real, reachable interleaving here, not a
    // theoretical one. Same fix as 11.3: one `@State`, one `.sheet(item:)`.
    private enum ActiveCallSheet: Identifiable {
        case report(CallReportRequestStore.PendingRequest)
        case confirm(CallConfirmRequestStore.PendingRequest)
        case missedCall(MissedCallReportRequestStore.PendingRequest)

        var id: UUID {
            switch self {
            case .report(let request): return request.id
            case .confirm(let request): return request.id
            case .missedCall(let request): return request.id
            }
        }
    }

    // Report, then confirm, then missed-call takes priority if (in
    // principle) more than one store somehow had a pending request at the
    // same instant — matches the real-world sequencing (`interrupt()`
    // always clears the report *before* a new confirm request is even
    // created) for report/confirm, and is an arbitrary-but-consistent
    // tie-break for missed-call, which has no such ordering guarantee
    // against the other two. Not expected to actually matter in practice;
    // whichever loses just stays queued and presents once the winner's
    // sheet dismisses and `refreshActiveCallSheet()` runs again.
    @State private var activeCallSheet: ActiveCallSheet?

    private func refreshActiveCallSheet() {
        let previousID = activeCallSheet?.id
        if let report = CallReportRequestStore.shared.pending {
            activeCallSheet = .report(report)
        } else if let confirm = CallConfirmRequestStore.shared.pending {
            activeCallSheet = .confirm(confirm)
        } else if let missedCall = MissedCallReportRequestStore.shared.pending {
            activeCallSheet = .missedCall(missedCall)
        } else {
            activeCallSheet = nil
        }

        // Bring the app (menu-bar-only, .accessory — no Dock icon to click)
        // to the front whenever a *new* sheet request appears — covers both
        // halves of the ask: call detection firing the confirm dialog
        // (`monitor.onCallStarted`/`onCallEnded` -> CallConfirmRequestStore)
        // and the report form opening (CallReportView/MissedCallReportView),
        // since both funnel through this same single `activeCallSheet`
        // (see its own doc comment for why report/confirm/missedCall share
        // one `.sheet(item:)`). Gated on the *id* actually changing, not
        // just "is non-nil" — `refreshActiveCallSheet()` reruns on every
        // didChange notification from any of the three stores, and
        // `activate(ignoringOtherApps:)` would otherwise yank focus away
        // from whatever the manager is doing mid-form on every unrelated
        // refresh, not just when a genuinely new dialog appears. Same
        // "activate + bring the one-and-only window front, deminiaturizing
        // if needed" pattern StatusItemController.openMainWindow() uses.
        if let activeCallSheet, activeCallSheet.id != previousID {
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApp.windows.first {
                // `makeKeyAndOrderFront` alone does NOT undo miniaturization
                // (the Dock genie-effect state) — that's a separate window
                // state AppKit tracks independently of front/back ordering,
                // unlike WPF's WindowState.Minimized which Windows'
                // RestoreIfMinimized() clears by setting WindowState.Normal
                // before its own Activate() call. Without this check, a
                // manager who minimized the window would see the app become
                // active/frontmost but the window itself stay collapsed as a
                // Dock icon — worth guarding explicitly rather than assuming
                // `makeKeyAndOrderFront` implies "not minimized" like it
                // would for a merely-background (not miniaturized) window.
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                window.makeKeyAndOrderFront(nil)
            }
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

    private let missedCallDidChangePublisher = NotificationCenter.default
        .publisher(for: MissedCallReportRequestStore.didChangeNotification)
        .receive(on: DispatchQueue.main)

    var body: some View {
        NavigationSplitView {
            List(AppScreen.allCases, selection: $selection) { screen in
                sidebarRow(for: screen)
                    .tag(screen)
                    .padding(.vertical, 2)
            }
            .listStyle(.sidebar)
            .navigationTitle("ReplixerMac")
            .navigationSplitViewColumnWidth(min: 190, ideal: 215, max: 260)
        } detail: {
            // Falls back to .home rather than a blank pane if selection
            // somehow goes nil (e.g. Cmd-click deselecting the sidebar row)
            // — AppScreen itself intentionally has no "none" case.
            screen(for: selection ?? .home)
        }
        .onReceive(sidebarStatusPublisher) { _ in
            isRecording = RecordingStatusStore.shared.status.isRecording
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
            case .missedCall(let request):
                MissedCallReportView(missedAt: request.missedAt)
                    .frame(width: 500, height: reportSheetHeight)
                    .interactiveDismissDisabled()
            }
        }
        .onReceive(reportDidChangePublisher) { _ in
            refreshActiveCallSheet()
        }
        .onReceive(confirmDidChangePublisher) { _ in
            refreshActiveCallSheet()
        }
        .onReceive(missedCallDidChangePublisher) { _ in
            refreshActiveCallSheet()
        }
        .onAppear {
            refreshActiveCallSheet()
        }
        // Windows parity: the toast stack floats bottom-right over the
        // whole window, independent of sidebar/detail selection — an
        // overlay on the root NavigationSplitView, not something threaded
        // into each individual screen.
        .overlay(alignment: .bottomTrailing) {
            ToastStackView()
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

    // Design-only: replaces the old bare `Label(screen.title,
    // systemImage:)` sidebar row with a small colorful icon badge (per-
    // screen tint, see `AppScreen.tintColor`) — same "each section gets its
    // own color" idiom Mail/Reminders use in their own sidebars — plus a
    // live pulsing dot on the Home row while a call is being recorded, so
    // "something is happening" is visible even when a different screen is
    // selected.
    @ViewBuilder
    private func sidebarRow(for screen: AppScreen) -> some View {
        Label {
            Text(screen.title)
        } icon: {
            ZStack(alignment: .topTrailing) {
                IconBadge(systemImage: screen.systemImage, tint: screen.tintColor, size: 22, shape: .roundedSquare)
                if screen == .home && isRecording {
                    Circle()
                        .fill(Theme.Status.recording)
                        .frame(width: 7, height: 7)
                        .overlay(Circle().stroke(.background, lineWidth: 1.5))
                        .offset(x: 3, y: -3)
                }
            }
        }
    }
}
