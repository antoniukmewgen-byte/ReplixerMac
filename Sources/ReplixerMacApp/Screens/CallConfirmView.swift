import SwiftUI
import ReplixerMacCore

/// Phase 11.1 — Windows parity source: `Views/Dialogs/CallDialogView.xaml` +
/// `CallDialogViewModel`. Shown for both "call detected, start recording?"
/// and "call ended, stop recording?" — `kind` picks the copy/color, same
/// object Windows uses just with an `isStop` bool derived from whether
/// `recordingStartedAt` is set.
///
/// Plain-@State-in-View, no formal ViewModel — same pattern as every other
/// mac screen (`CallReportView`, `SettingsView`, ...). No cancel/dismiss
/// affordance beyond the two buttons themselves — `ContentView`'s
/// `.interactiveDismissDisabled()` blocks Esc/swipe-away, matching Windows
/// (`CallDialogViewModel` has no third "just close it" path either) and
/// avoiding an orphaned `CallConfirmRequestStore` continuation that would
/// otherwise hang `AppDelegate`'s monitor `Task` forever.
struct CallConfirmView: View {
    let kind: CallConfirmRequestStore.Kind
    let platform: String
    let recordingStartedAt: Date?

    // Windows parity: `CallDialogViewModel.IsConfirming` — only the "skip
    // recording" secondary action (kind == .start) needs a second "are you
    // sure" tap before it actually dismisses; "continue recording" (kind ==
    // .end's secondary) fires immediately, same as Windows' `OnCallEnded`
    // dialog never passing `confirmSecondary: true`.
    @State private var isConfirmingSkip = false
    @State private var now = Date()

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var secondaryNeedsConfirm: Bool { kind == .start }

    private var message: String {
        if isConfirmingSkip {
            return "Ви впевнені, що хочете відмінити?"
        }
        switch kind {
        case .start:
            return "Виявлено дзвінок. Бажаєте розпочати запис розмови?"
        case .end:
            return "Дзвінок завершено. Зупинити запис?"
        }
    }

    private var primaryLabel: String {
        kind == .start ? "Почати запис" : "Завершити запис"
    }

    private var secondaryLabel: String {
        kind == .start ? "Пропустити" : "Продовжити запис"
    }

    private var accentColor: Color {
        kind == .start ? .green : .red
    }

    private var elapsedText: String? {
        guard kind == .end, let recordingStartedAt else { return nil }
        let elapsed = max(0, now.timeIntervalSince(recordingStartedAt))
        return Self.elapsedFormatter.string(from: elapsed)
    }

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: kind == .start ? "phone.arrow.down.left.fill" : "phone.down.fill")
                .font(.system(size: 34))
                .foregroundStyle(accentColor)

            VStack(spacing: 4) {
                Text(platform)
                    .font(.headline)
                if let elapsedText {
                    Text(elapsedText)
                        .font(.title3)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            Text(message)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Button(secondaryLabel) { handleSecondary() }
                    .keyboardShortcut(.cancelAction)

                Button(isConfirmingSkip ? "Назад" : primaryLabel) { handlePrimary() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(isConfirmingSkip ? .secondary : accentColor)
            }
        }
        .padding(24)
        .onReceive(timer) { date in now = date }
    }

    // Windows parity (`CallDialogViewModel.PrimaryCommand`): while the
    // "are you sure?" confirm step is showing, the primary button doesn't
    // perform its normal action — it just backs out of the confirm step and
    // returns to the original dialog.
    private func handlePrimary() {
        if isConfirmingSkip {
            isConfirmingSkip = false
            return
        }
        CallConfirmRequestStore.shared.submit(true)
    }

    // Windows parity (`CallDialogViewModel.SecondaryCommand`): the first tap
    // on a confirm-gated secondary just arms the confirm step; the dialog
    // only actually resolves "false" on a second tap (or immediately, for
    // secondary actions that don't need confirming at all).
    private func handleSecondary() {
        if secondaryNeedsConfirm && !isConfirmingSkip {
            isConfirmingSkip = true
            return
        }
        CallConfirmRequestStore.shared.submit(false)
    }

    private static let elapsedFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }()
}
