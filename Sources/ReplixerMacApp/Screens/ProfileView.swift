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

    // Phase 10.1c fix, extended after the "isReadyToAutoSave" attempt below
    // turned out not to be enough: `googleServiceAccountPath`'s doc comment
    // (AppSettings.swift) references a prior "telegramApiHash null-wipe"
    // where a `SecureField`'s `.onChange` fired with an empty string it
    // never actually displayed, and the save function treated "empty" as
    // "user wants to clear this setting", silently nil-ing out a real saved
    // value. The `isReadyToAutoSave` guard below (ignore only the *first*
    // onChange this view instance ever sees) fixed the initial-mount case,
    // but the exact same wipe kept recurring for kommoApiToken specifically
    // — because on macOS a `SecureField` can re-fire `onChange` with `""`
    // any time its underlying secure text-entry field gets torn down and
    // rebuilt (window losing/regaining key status — switching away and
    // back, sleep/wake, or simply relaunching after a reboot), not just at
    // first mount. `isReadyToAutoSave` only ever protects the *very first*
    // occurrence, so any later phantom reset sails straight through and
    // gets auto-saved as "user cleared the field", permanently losing the
    // real token days after it was actually typed.
    //
    // Fix: `onChange` on a `SecureField` never saves an empty value anymore
    // (see `saveKommoApiToken`/`saveTelegramApiHash` below) — a phantom
    // reset is now just ignored, no write happens. Clearing the setting on
    // purpose still works via `onSubmit` (pressing Return on an emptied
    // field is an explicit user gesture, not something AppKit fires on its
    // own) or the "Очистити" button next to each field, which is the more
    // discoverable affordance for a password-style control anyway. Plain
    // `TextField`s (kommoSubdomain, the Telegram numeric fields, Drive
    // folder id) aren't known to have this AppKit-level teardown/rebuild
    // quirk, so they keep the simpler "empty onChange clears it" behavior.
    @State private var isReadyToAutoSave = false

    var body: some View {
        Form {
            // Design-only: `Label` section headers (matching SettingsView's
            // same treatment) and `Theme.Status.*` in place of the old bare
            // `.green`/`.orange` — no field, onChange, or save/clear logic
            // below changed.
            Section {
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
                            .foregroundStyle(Theme.Status.saved)
                    case .failure(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.Status.warning)
                    }
                }
            } header: {
                Label("Google Drive", systemImage: "externaldrive.fill")
            }

            Section {
                TextField("API ID", text: $telegramApiId)
                    .onSubmit(saveTelegramApiId)
                    .onChange(of: telegramApiId) { _, _ in
                        guard isReadyToAutoSave else { return }
                        saveTelegramApiId()
                    }
                HStack(spacing: 8) {
                    SecureField("API Hash", text: $telegramApiHash)
                        .onSubmit(saveTelegramApiHash)
                        .onChange(of: telegramApiHash) { _, newValue in
                            guard isReadyToAutoSave else { return }
                            // See isReadyToAutoSave's doc comment above — a
                            // SecureField's onChange never treats an empty
                            // value as an intentional clear; only onSubmit
                            // (explicit Return) or the button below do that.
                            guard !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                            saveTelegramApiHash()
                        }
                    Button("Очистити", role: .destructive, action: clearTelegramApiHash)
                        .disabled(telegramApiHash.isEmpty)
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
                        .foregroundStyle(Theme.Status.saved)
                } else {
                    Label("Сесії ще немає", systemImage: "circle")
                        .foregroundStyle(.secondary)
                    Text("Перша авторизація виконується через консоль Xcode (`--telegram-login-smoke-test`) — після неї сесія збережеться і ця сторінка покаже \"Сесія збережена\".")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("Telegram", systemImage: "paperplane.fill")
            }

            Section {
                TextField("Subdomain (напр. myaccount)", text: $kommoSubdomain)
                    .onSubmit(saveKommoSubdomain)
                    .onChange(of: kommoSubdomain) { _, _ in
                        guard isReadyToAutoSave else { return }
                        saveKommoSubdomain()
                    }
                HStack(spacing: 8) {
                    SecureField("API токен", text: $kommoApiToken)
                        .onSubmit(saveKommoApiToken)
                        .onChange(of: kommoApiToken) { _, newValue in
                            guard isReadyToAutoSave else { return }
                            // Same reasoning as telegramApiHash's onChange
                            // above — never let a phantom empty fire wipe a
                            // real saved token.
                            guard !newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
                            saveKommoApiToken()
                        }
                    Button("Очистити", role: .destructive, action: clearKommoApiToken)
                        .disabled(kommoApiToken.isEmpty)
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
                            .foregroundStyle(Theme.Status.saved)
                    case .failure(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.Status.warning)
                    }
                }
            } header: {
                Label("Kommo CRM", systemImage: "person.crop.circle.badge.checkmark")
            }

            Section {
                Text("Заплановано на Phase 10.")
                    .foregroundStyle(.secondary)
            } header: {
                Label("Google Sheets", systemImage: "tablecells.fill")
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

    // Explicit-clear path for the "Очистити" button next to the SecureField
    // — the one place besides onSubmit that's allowed to persist an empty
    // value, since a button tap (unlike onChange) can never be a phantom
    // AppKit-internal refire.
    private func clearTelegramApiHash() {
        telegramApiHash = ""
        AppSettings.shared.telegramApiHash = nil
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

    // See clearTelegramApiHash's doc comment above — same reasoning.
    private func clearKommoApiToken() {
        kommoApiToken = ""
        AppSettings.shared.kommoApiToken = nil
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
