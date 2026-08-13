import SwiftUI
import AppKit
import UniformTypeIdentifiers
import ReplixerMacCore

/// Phase 7.6 — Windows parity source: `ProfileViewModel` (486 lines), scoped
/// per the plan to Google Drive + Telegram sections only; Kommo/Google
/// Sheets stayed stubbed pending Phase 10 backends. Phase 10.1a added a real
/// Kommo section (subdomain/token + "Перевірити з'єднання", same pattern as
/// Drive's below) once `KommoService` existed to back it — Google Sheets
/// still has no service to call, so it stays a placeholder.
///
/// Same local-@State-mirror-of-a-plain-class pattern as SettingsView (mac
/// `AppSettings` isn't an `ObservableObject`, ReplixerMacCore stays
/// SwiftUI-free by design), extended here to numeric fields
/// (`telegramApiId`/`telegramChatId`/`telegramTopicId`) that need
/// String<->Int bridging since SwiftUI text entry is string-based.
///
/// **Deliberate scope cut vs. Windows:** Windows' Profile screen drives a
/// full interactive phone+code+2FA Telegram login right from this screen
/// (`ProfileViewModel`'s `AuthorizeCommand` + a modal input dialog). Mac's
/// `TelegramAuthClient.login()` still prompts for that over blocking
/// `readLine()` (see its doc comment) — safe today only because testing
/// happens through Xcode's console, which forwards typed input to a
/// debugger-launched process's stdin. Wiring a button in this screen
/// directly to `login()` would hang indefinitely in a real double-clicked
/// `.app` (no console, nothing to satisfy that `readLine()`) for anyone
/// without a session already on disk — so this screen surfaces the
/// credential fields and a non-interactive "is a session already saved?"
/// readout (`TelegramAuthClient.hasSavedSession`), but no "Authorize"
/// button. First-time login still goes through
/// `--telegram-login-smoke-test` (Xcode console) until a properly
/// UI-driven (non-stdin) login flow is designed — that redesign is out of
/// scope for this sub-phase.
struct ProfileView: View {
    @State private var driveFolderId: String = AppSettings.shared.googleDriveFolderId ?? ""
    @State private var serviceAccountPath: String = AppSettings.shared.googleServiceAccountPath ?? ""
    @State private var isTestingDriveConnection = false
    @State private var driveTestResult: GoogleDriveFolderAccessSmokeTest.CheckOutcome?

    @State private var telegramApiId: String = AppSettings.shared.telegramApiId.map(String.init) ?? ""
    @State private var telegramApiHash: String = AppSettings.shared.telegramApiHash ?? ""
    @State private var telegramChatId: String = AppSettings.shared.telegramChatId.map(String.init) ?? ""
    @State private var telegramTopicId: String = AppSettings.shared.telegramTopicId.map(String.init) ?? ""
    // Snapshotted on appear, not recomputed per-render — it's a filesystem
    // stat, not a SwiftUI-observable value, and this screen has no signal
    // that would tell it to refresh mid-session anyway (no UI here ever
    // creates or deletes the session).
    @State private var telegramHasSavedSession = TelegramAuthClient.hasSavedSession

    // Phase 10.1a
    @State private var kommoSubdomain: String = AppSettings.shared.kommoSubdomain ?? ""
    @State private var kommoApiToken: String = AppSettings.shared.kommoApiToken ?? ""
    @State private var isTestingKommoConnection = false
    @State private var kommoTestResult: KommoService.CheckOutcome?

    // Phase 10.1c fix — guards every onChange-triggered auto-save below
    // against a real incident: `googleServiceAccountPath`'s doc comment
    // (AppSettings.swift) references a prior "telegramApiHash null-wipe"
    // where a `SecureField`'s `.onChange` fired once with an empty string
    // during this view's initial mount (a known SwiftUI quirk — the field
    // hasn't visually settled to its @State-seeded prefill yet), and the
    // save function below treats "empty" as "user wants to clear this
    // setting", silently nil-ing out a real saved value. The exact same
    // thing then happened again to kommoSubdomain/kommoApiToken. Unlike
    // SettingsView's managerName (which sidesteps this by simply never
    // saving an empty value at all — empty is never a legitimate state for
    // it), empty genuinely IS a valid, intentional state here (disconnecting
    // Kommo/Telegram/Drive), so the fields can't just ignore empty forever.
    // Instead: ignore only the *first* onChange this view instance ever
    // sees, deferred one runloop tick past onAppear so it also swallows any
    // phantom call that fires during the initial layout pass. A genuine
    // first keystroke just has its save deferred to the next keystroke/
    // onSubmit/field-blur, which is harmless.
    @State private var isReadyToAutoSave = false

    var body: some View {
        Form {
            Section("Google Drive") {
                TextField("ID теки Google Drive", text: $driveFolderId)
                    .onSubmit(saveDriveFolderId)
                    .onChange(of: driveFolderId) { _, _ in
                        guard isReadyToAutoSave else { return }
                        saveDriveFolderId()
                    }

                LabeledContent("Service account") {
                    HStack(spacing: 8) {
                        Text(serviceAccountPath.isEmpty ? "Не обрано" : serviceAccountPath)
                            .foregroundStyle(serviceAccountPath.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Обрати файл...", action: pickServiceAccountFile)
                    }
                }

                Button {
                    testDriveConnection()
                } label: {
                    if isTestingDriveConnection {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Перевірити з'єднання")
                    }
                }
                .disabled(isTestingDriveConnection)

                if let driveTestResult {
                    switch driveTestResult {
                    case .success(let message):
                        Label(message, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failure(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("Telegram") {
                TextField("API ID", text: $telegramApiId)
                    .onSubmit(saveTelegramApiId)
                    .onChange(of: telegramApiId) { _, _ in
                        guard isReadyToAutoSave else { return }
                        saveTelegramApiId()
                    }
                SecureField("API Hash", text: $telegramApiHash)
                    .onSubmit(saveTelegramApiHash)
                    .onChange(of: telegramApiHash) { _, _ in
                        guard isReadyToAutoSave else { return }
                        saveTelegramApiHash()
                    }
                TextField("ID чату", text: $telegramChatId)
                    .onSubmit(saveTelegramChatId)
                    .onChange(of: telegramChatId) { _, _ in
                        guard isReadyToAutoSave else { return }
                        saveTelegramChatId()
                    }
                TextField("ID теми (опційно)", text: $telegramTopicId)
                    .onSubmit(saveTelegramTopicId)
                    .onChange(of: telegramTopicId) { _, _ in
                        guard isReadyToAutoSave else { return }
                        saveTelegramTopicId()
                    }

                if telegramHasSavedSession {
                    Label("Сесія збережена на диску", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Сесії ще немає", systemImage: "circle")
                        .foregroundStyle(.secondary)
                    Text("Перша авторизація виконується через консоль Xcode (`--telegram-login-smoke-test`) — після неї сесія збережеться і ця сторінка покаже \"Сесія збережена\".")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Kommo CRM") {
                TextField("Subdomain (напр. myaccount)", text: $kommoSubdomain)
                    .onSubmit(saveKommoSubdomain)
                    .onChange(of: kommoSubdomain) { _, _ in
                        guard isReadyToAutoSave else { return }
                        saveKommoSubdomain()
                    }
                SecureField("API токен", text: $kommoApiToken)
                    .onSubmit(saveKommoApiToken)
                    .onChange(of: kommoApiToken) { _, _ in
                        guard isReadyToAutoSave else { return }
                        saveKommoApiToken()
                    }

                Button {
                    testKommoConnection()
                } label: {
                    if isTestingKommoConnection {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Перевірити з'єднання")
                    }
                }
                .disabled(isTestingKommoConnection)

                if let kommoTestResult {
                    switch kommoTestResult {
                    case .success(let message):
                        Label(message, systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failure(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }

            Section("Google Sheets") {
                Text("Заплановано на Phase 10.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Профіль")
        // See isReadyToAutoSave's doc comment above — deliberately deferred
        // one runloop tick past onAppear (not set true directly inside it)
        // so this also outlasts any phantom empty-value onChange firing
        // during the same initial layout pass onAppear itself belongs to.
        .onAppear {
            DispatchQueue.main.async {
                isReadyToAutoSave = true
            }
        }
    }

    private func saveDriveFolderId() {
        let trimmed = driveFolderId.trimmingCharacters(in: .whitespacesAndNewlines)
        AppSettings.shared.googleDriveFolderId = trimmed.isEmpty ? nil : trimmed
    }

    private func pickServiceAccountFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        serviceAccountPath = url.path
        AppSettings.shared.googleServiceAccountPath = url.path
    }

    private func testDriveConnection() {
        isTestingDriveConnection = true
        driveTestResult = nil
        Task {
            let result = await GoogleDriveFolderAccessSmokeTest.check()
            isTestingDriveConnection = false
            driveTestResult = result
        }
    }

    // Empty clears the setting (unlike SettingsView's managerName, empty is
    // a valid state here — these fields start out unset on every fresh
    // install). Non-empty-but-unparseable input is silently ignored rather
    // than saved, same "don't save garbage, don't explain why here either"
    // stance as managerName's whitespace-only rejection.
    private func saveTelegramApiId() {
        let trimmed = telegramApiId.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            AppSettings.shared.telegramApiId = nil
        } else if let value = Int(trimmed) {
            AppSettings.shared.telegramApiId = value
        }
    }

    private func saveTelegramApiHash() {
        let trimmed = telegramApiHash.trimmingCharacters(in: .whitespacesAndNewlines)
        AppSettings.shared.telegramApiHash = trimmed.isEmpty ? nil : trimmed
    }

    private func saveTelegramChatId() {
        let trimmed = telegramChatId.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            AppSettings.shared.telegramChatId = nil
        } else if let value = Int64(trimmed) {
            AppSettings.shared.telegramChatId = value
        }
    }

    private func saveTelegramTopicId() {
        let trimmed = telegramTopicId.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            AppSettings.shared.telegramTopicId = nil
        } else if let value = Int(trimmed) {
            AppSettings.shared.telegramTopicId = value
        }
    }

    // Same "empty clears the setting" stance as the Telegram fields above —
    // both start out unset on every fresh install.
    private func saveKommoSubdomain() {
        let trimmed = kommoSubdomain.trimmingCharacters(in: .whitespacesAndNewlines)
        AppSettings.shared.kommoSubdomain = trimmed.isEmpty ? nil : trimmed
    }

    private func saveKommoApiToken() {
        let trimmed = kommoApiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        AppSettings.shared.kommoApiToken = trimmed.isEmpty ? nil : trimmed
    }

    private func testKommoConnection() {
        isTestingKommoConnection = true
        kommoTestResult = nil
        Task {
            let result = await KommoService.testConnection()
            isTestingKommoConnection = false
            kommoTestResult = result
        }
    }
}
