import SwiftUI
import ReplixerMacCore

/// Phase 7.8 — interactive Telegram phone+code+2FA authorize flow, shared by
/// `SetupWizardView`'s Telegram card and `ProfileView`'s Telegram section.
/// Windows parity: the same `AuthorizeCommand`+`InputDialogViewModel`
/// pattern backs both `SetupWindow.xaml` and `ProfilePage.xaml`'s Telegram
/// cards there — kept in one shared view here for the same reason, plus it's
/// the one place the tricky async-continuation bridge (TDLib's callback-
/// driven `inputHandler` calls, answered by a SwiftUI sheet) needs to be
/// written and gotten right.
///
/// Deliberately does NOT include the destination chat `Picker` (Windows'
/// `FilteredTelegramChats`/`SelectedTelegramChat`) — `ProfileView` already
/// has that (`selectedTelegramChat`, gated on `isTelegramEnabled`) and
/// `SetupWizardView` points first-run users at Profile for it, same as it
/// already does for Drive/Kommo. This view owns only the auth handshake
/// itself: phone field, Authorize/Log out buttons, and a status readout.
struct TelegramAuthSection: View {
    @State private var phone: String = AppSettings.shared.telegramPhone ?? ""
    @State private var isAuthorizing = false
    @State private var authError: String?
    // Snapshotted like ProfileView's old `telegramHasSavedSession` — a
    // filesystem stat, not a SwiftUI-observable value; refreshed explicitly
    // after every authorize()/logout() call rather than polled.
    @State private var hasSavedSession = TelegramAuthClient.hasSavedSession
    @State private var pendingPrompt: TelegramInputPrompt?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Номер телефону (напр. +380...)", text: $phone)
                .textFieldStyle(.roundedBorder)
                .disabled(isAuthorizing)
                .onSubmit(authorize)

            HStack(spacing: 12) {
                Button {
                    authorize()
                } label: {
                    if isAuthorizing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(hasSavedSession ? "Переавторизувати" : "Авторизувати")
                    }
                }
                .disabled(isAuthorizing || phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                if hasSavedSession {
                    Button("Вийти", role: .destructive) {
                        logout()
                    }
                    .disabled(isAuthorizing)
                }
            }

            if hasSavedSession {
                Label("Доступ підключено", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Theme.Status.saved)
            } else if !isAuthorizing {
                Label("Сесії ще немає", systemImage: "circle")
                    .foregroundStyle(.secondary)
            }

            if let authError {
                Label(authError, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Status.warning)
            }
        }
        .sheet(item: $pendingPrompt) { prompt in
            TelegramInputPromptView(prompt: prompt)
        }
    }

    private func authorize() {
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAuthorizing else { return }
        AppSettings.shared.telegramPhone = trimmed
        isAuthorizing = true
        authError = nil

        let client = TelegramAuthClient()
        Task {
            do {
                try await client.login(phone: trimmed, inputHandler: { prompt, isSecure in
                    await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
                        Task { @MainActor in
                            pendingPrompt = TelegramInputPrompt(text: prompt, isSecure: isSecure) { answer in
                                pendingPrompt = nil
                                continuation.resume(returning: answer)
                            }
                        }
                    }
                })
                isAuthorizing = false
                hasSavedSession = true
            } catch TelegramAuthError.cancelled {
                isAuthorizing = false
            } catch TelegramAuthError.missingCredentials {
                isAuthorizing = false
                authError = "AppSecrets.telegramApiId/telegramApiHash не налаштовані в цій збірці."
            } catch TelegramAuthError.registrationNotSupported {
                isAuthorizing = false
                authError = "Цей номер не зареєстрований у Telegram."
            } catch {
                isAuthorizing = false
                authError = "Не вдалося авторизуватись: \(error)"
            }
        }
    }

    private func logout() {
        TelegramAuthClient.logout()
        hasSavedSession = false
        authError = nil
    }
}

/// One interactive text prompt (verification code or 2FA password) —
/// SwiftUI equivalent of Windows' `InputDialogViewModel`.
struct TelegramInputPrompt: Identifiable {
    let id = UUID()
    let text: String
    let isSecure: Bool
    let onComplete: (String?) -> Void
}

private struct TelegramInputPromptView: View {
    let prompt: TelegramInputPrompt
    @State private var input = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(prompt.text)
                .font(.headline)

            Group {
                if prompt.isSecure {
                    SecureField("Введіть тут", text: $input)
                } else {
                    TextField("Введіть тут", text: $input)
                }
            }
            .textFieldStyle(.roundedBorder)
            .onSubmit(confirm)

            HStack {
                Spacer()
                Button("Скасувати", role: .cancel) {
                    complete(with: nil)
                }
                Button("Підтвердити") {
                    confirm()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 360)
    }

    private func confirm() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        complete(with: trimmed)
    }

    private func complete(with answer: String?) {
        prompt.onComplete(answer)
        dismiss()
    }
}
