import SwiftUI
import ReplixerMacCore

/// Phase 7.7 — first-launch welcome screen. Windows-parity source:
/// `SetupViewModel`/`SetupWindow.xaml` (426/1140 lines) — but scoped down
/// hard. Windows' wizard is a one-stop shop that configures *everything*
/// in one modal: manager name + Position (gates a hardcoded Telegram-chat
/// picker), Google Drive folder + test button, Kommo subdomain/token + test
/// button, Google Sheets id/tab + test button, and an interactive Telegram
/// phone/code/2FA login flow with its own modal input dialog.
///
/// None of that carries over here:
/// - **Position** doesn't exist as a mac concept (nothing reads it — no
///   chat-picker to gate, no Kommo/Sheets visibility policy).
/// - **Kommo / Google Sheets** aren't built yet (Phase 10) — same reason
///   ProfileView stubs them instead of showing live fields.
/// - **Google Drive / Telegram credential fields** already have a real,
///   working home: `ProfileView` (Phase 7.6), complete with its own
///   non-blocking "Перевірити з'єднання" button and a safe
///   `hasSavedSession` readout. Duplicating those fields into a wizard
///   would just be a second, easier-to-desync copy of the same UI.
/// - **Telegram "Authorize" button**: `TelegramAuthClient.login()` blocks
///   on `readLine()` (see its doc comment) — unsafe from any button in a
///   double-clicked `.app` with no console. ProfileView already made this
///   call for Phase 7.6; the wizard inherits the same constraint and the
///   same answer (no button, point at the Xcode-console smoke test for
///   first-time login).
///
/// So this screen is reduced to its one truly required piece: confirming
/// `managerName` (used directly in every recording's filename — an empty
/// value would produce garbled names, same validation stance as
/// `SettingsView.saveManagerName`) — plus a short pointer at Profile for
/// everything else — and a "Почати роботу" button that flips
/// `AppSettings.isSetupComplete` to `true` so this screen doesn't show
/// again.
struct SetupWizardView: View {
    /// Called once the user taps "Почати роботу" — `ContentView` uses this
    /// to dismiss the sheet, rather than this view reaching into
    /// presentation state it doesn't own.
    var onFinish: () -> Void

    @State private var managerName: String = AppSettings.shared.managerName

    private var trimmedName: String {
        managerName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ласкаво просимо до ReplixerMac")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("Підтверди своє ім'я, щоб продовжити. Google Drive та Telegram можна налаштувати пізніше на сторінці «Профіль».")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            TextField("Ім'я менеджера", text: $managerName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(finish)

            Spacer()

            HStack {
                Spacer()
                Button("Почати роботу", action: finish)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmedName.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420, height: 240)
    }

    private func finish() {
        guard !trimmedName.isEmpty else { return }
        AppSettings.shared.managerName = trimmedName
        AppSettings.shared.isSetupComplete = true
        onFinish()
    }
}

#Preview {
    SetupWizardView(onFinish: {})
}
