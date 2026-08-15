import SwiftUI
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
/// SwiftUI-free by design). Telegram's destination is a `Picker` over
/// `AppSecrets.telegramChats` (see `selectedTelegramChat` below) rather
/// than raw chat-id/topic-id text entry — matching Windows'
/// `FilteredTelegramChats`/`SelectedTelegramChat` `ComboBox`.
/// `telegramApiId`/`telegramApiHash` moved out of this screen entirely —
/// like `googleServiceAccountJson`, they're now a build-time `AppSecrets`
/// constant, not a per-user setting (see `AppSecrets.example.swift`), so
/// there's nothing here left to edit.
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
// SwiftUI's `Picker` logs "the selection ... is invalid and does not have an
// associated tag" when an `Optional<T>`-typed selection is paired with a
// `nil`-tagged placeholder row alongside `ForEach`-generated non-nil tags —
// a known framework quirk, not a sign of a real data/logic bug (the filter
// logic backing `selectedTelegramChat` was independently verified sound).
// Sidestepped structurally by never using a `nil` tag at all: `.none` is
// itself a valid, non-optional case, so every row Picker ever sees has a
// concrete tag.
private enum TelegramChatSelection: Hashable {
    case none
    case chat(TelegramChat)
}

struct ProfileView: View {
    // Phase 12: Windows parity `ProfileViewModel.IsGoogleDriveEnabled` — a
    // real opt-out toggle on top of folder-id presence (see
    // AppSettings.isGoogleDriveEnabled's doc comment). onChange writes
    // straight back to AppSettings, same pattern as every other field on
    // this screen.
    @State private var isDriveEnabled = AppSettings.shared.isGoogleDriveEnabled
    // Sanitized on read, not just on save — GoogleDriveFolderId.sanitize
    // (ReplixerMacCore) handles a value that was saved before this
    // sanitization existed (see its doc comment); onAppear below also
    // writes the corrected value back to AppSettings via
    // `sanitizedFromSettings()` if it differs from what's stored, so
    // background uploads that run before this screen is ever opened
    // self-heal too, not just this text field.
    @State private var driveFolderId: String =
        GoogleDriveFolderId.sanitize(AppSettings.shared.googleDriveFolderId ?? "")
    @State private var isTestingDriveConnection = false
    // Seeded from AppSettings.isDriveConnected (not always nil) so a
    // previously-verified connection shows its green "Доступ підключено"
    // label immediately on appear, without forcing a fresh
    // "Перевірити з'єднання" click every time this screen opens. Overwritten
    // by every future testDriveConnection() call, and reset back to nil the
    // moment driveFolderId is edited (saveDriveFolderId) — an unverified
    // edit shouldn't keep showing a stale green label.
    @State private var driveTestResult: GoogleDriveFolderAccessSmokeTest.CheckOutcome? =
        AppSettings.shared.isDriveConnected ? .success("Доступ підключено") : nil

    // Windows parity: `ProfileViewModel.FilteredTelegramChats`/
    // `SelectedTelegramChat` — a picker over `AppSecrets.telegramChats`
    // (filtered by role via `PositionPolicy.filteredTelegramChats`) instead
    // of raw chat-id/topic-id text entry. Position doesn't change while
    // this view is on screen (it's a separate sidebar destination from
    // Settings, never rendered simultaneously), so computing the filtered
    // list once here — rather than reactively, like Windows' cross-VM
    // property-changed plumbing — is enough.
    // Phase 12: Windows parity `ProfileViewModel.IsTelegramEnabled` — see
    // isDriveEnabled above for the same reasoning.
    @State private var isTelegramEnabled = AppSettings.shared.isTelegramEnabled
    private let filteredTelegramChats = ProfileView.computeFilteredTelegramChats()
    // Initial selection mirrors Windows' constructor logic: Кваліфікатор
    // always lands on the one chat it's allowed to see; every other role
    // matches whatever chat/topic id pair is already saved (nil if none
    // saved yet, or if the saved id no longer matches any configured
    // chat — e.g. `AppSecrets.telegramChats` hasn't been filled in).
    @State private var selectedTelegramChat: TelegramChatSelection = ProfileView.initialSelectedTelegramChat()
    // Snapshotted on appear, not recomputed per-render — it's a filesystem
    // stat, not a SwiftUI-observable value, and this screen has no signal
    // that would tell it to refresh mid-session anyway (no UI here ever
    // creates or deletes the session).
    @State private var telegramHasSavedSession = TelegramAuthClient.hasSavedSession

    // Phase 12: Windows parity `ProfileViewModel.IsKommoEnabled` — see
    // isDriveEnabled above for the same reasoning.
    @State private var isKommoEnabled = AppSettings.shared.isKommoEnabled

    // Phase 10.1a
    @State private var kommoSubdomain: String = AppSettings.shared.kommoSubdomain ?? ""
    @State private var kommoApiToken: String = AppSettings.shared.kommoApiToken ?? ""
    @State private var isTestingKommoConnection = false
    // Same persisted-status seeding as driveTestResult above.
    @State private var kommoTestResult: KommoService.CheckOutcome? =
        AppSettings.shared.isKommoConnected ? .success("Доступ підключено") : nil

    // Phase 10.1c fix, extended after the "isReadyToAutoSave" attempt below
    // turned out not to be enough: a prior "telegramApiHash null-wipe"
    // incident where a `SecureField`'s `.onChange` fired with an empty string it
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
    // (see `saveKommoApiToken` below) — a phantom
    // reset is now just ignored, no write happens. Clearing the setting on
    // purpose still works via `onSubmit` (pressing Return on an emptied
    // field is an explicit user gesture, not something AppKit fires on its
    // own) — no separate "Очистити" button exists for this field. Plain
    // `TextField`s (kommoSubdomain, Drive folder id) aren't known to have
    // this AppKit-level teardown/rebuild quirk, so they keep the simpler
    // "empty onChange clears it" behavior.
    @State private var isReadyToAutoSave = false

    var body: some View {
        Form {
            // Design-only: `Label` section headers (matching SettingsView's
            // same treatment) and `Theme.Status.*` in place of the old bare
            // `.green`/`.orange` — no field, onChange, or save/clear logic
            // below changed.
            Section {
                Toggle("Автоматично завантажувати запис на Google Drive", isOn: $isDriveEnabled)
                    .onChange(of: isDriveEnabled) { _, newValue in
                        AppSettings.shared.isGoogleDriveEnabled = newValue
                    }

                if isDriveEnabled {
                    TextField("ID теки Google Drive", text: $driveFolderId)
                        .onSubmit(saveDriveFolderId)
                        .onChange(of: driveFolderId) { _, _ in
                            guard isReadyToAutoSave else { return }
                            saveDriveFolderId()
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
                }
            } header: {
                Label("Google Drive", systemImage: "externaldrive.fill")
            }

            Section {
                Toggle("Автоматично надсилати запис у Telegram", isOn: $isTelegramEnabled)
                    .onChange(of: isTelegramEnabled) { _, newValue in
                        AppSettings.shared.isTelegramEnabled = newValue
                    }

                if isTelegramEnabled {
                    Picker("Чат", selection: $selectedTelegramChat) {
                        Text("Оберіть чат").tag(TelegramChatSelection.none)
                        ForEach(filteredTelegramChats) { chat in
                            Text(chat.name).tag(TelegramChatSelection.chat(chat))
                        }
                    }
                    .onChange(of: selectedTelegramChat) { _, newValue in
                        guard case .chat(let chat) = newValue else { return }
                        AppSettings.shared.telegramChatId = chat.chatId
                        AppSettings.shared.telegramTopicId = chat.topicId
                    }

                    if filteredTelegramChats.isEmpty {
                        Text("Список чатів порожній — заповніть `AppSecrets.telegramChats` реальними TDLib id (див. `--telegram-list-chats-smoke-test`).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if telegramHasSavedSession {
                        // Same "Доступ підключено" wording as Drive/Kommo above
                        // — a saved TDLib session on disk (checked via
                        // `TelegramAuthClient.hasSavedSession`) is this
                        // section's equivalent of a verified connection, so it
                        // gets the same green label instead of a differently-
                        // worded one.
                        Label("Доступ підключено", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.Status.saved)
                    } else {
                        Label("Сесії ще немає", systemImage: "circle")
                            .foregroundStyle(.secondary)
                        Text("Перша авторизація виконується через консоль Xcode (`--telegram-login-smoke-test`) — після неї сесія збережеться і ця сторінка покаже \"Доступ підключено\".")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Label("Telegram", systemImage: "paperplane.fill")
            }

            Section {
                Toggle("Автоматично додавати нотатку в угоду Kommo", isOn: $isKommoEnabled)
                    .onChange(of: isKommoEnabled) { _, newValue in
                        AppSettings.shared.isKommoEnabled = newValue
                    }

                if isKommoEnabled {
                    TextField("Subdomain (напр. myaccount)", text: $kommoSubdomain)
                        .onSubmit(saveKommoSubdomain)
                        .onChange(of: kommoSubdomain) { _, _ in
                            guard isReadyToAutoSave else { return }
                            saveKommoSubdomain()
                        }
                    // No "Очистити" button here (unlike the old telegramApiHash
                    // field this replaced) — pressing Return on an emptied
                    // field (onSubmit) is still an explicit, discoverable way
                    // to clear a saved token on purpose; see saveKommoApiToken.
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
        .onAppear {
            // Self-heal a Drive folder id that got saved before
            // GoogleDriveFolderId.sanitize existed — see that type's doc
            // comment for exactly how a stray "?hl=ru" left over from a
            // copy-pasted browser URL let "Перевірити з'єднання" report
            // success while every real upload still 404'd. This mirrors
            // `driveFolderId`'s own initializer above; done again here (not
            // just there) because `sanitizedFromSettings()` is also the
            // thing that writes the corrected value back to AppSettings —
            // the initializer alone only fixes what this text field shows.
            if let sanitized = GoogleDriveFolderId.sanitizedFromSettings(), sanitized != driveFolderId {
                driveFolderId = sanitized
                AppSettings.shared.isDriveConnected = false
                driveTestResult = nil
            }
            // See isReadyToAutoSave's doc comment above — deliberately deferred
            // one runloop tick past onAppear (not set true directly inside it)
            // so this also outlasts any phantom empty-value onChange firing
            // during the same initial layout pass onAppear itself belongs to.
            DispatchQueue.main.async {
                isReadyToAutoSave = true
            }
        }
    }

    private func saveDriveFolderId() {
        let sanitized = GoogleDriveFolderId.sanitize(driveFolderId)
        if sanitized != driveFolderId {
            driveFolderId = sanitized
        }
        AppSettings.shared.googleDriveFolderId = sanitized.isEmpty ? nil : sanitized
        // Edited without re-verifying — don't keep showing a green label for
        // a folder id nobody has actually confirmed access to yet.
        AppSettings.shared.isDriveConnected = false
        driveTestResult = nil
    }

    private func testDriveConnection() {
        isTestingDriveConnection = true
        driveTestResult = nil
        Task {
            let result = await GoogleDriveFolderAccessSmokeTest.check()
            isTestingDriveConnection = false
            switch result {
            case .success:
                AppSettings.shared.isDriveConnected = true
                driveTestResult = .success("Доступ підключено")
            case .failure(let message):
                AppSettings.shared.isDriveConnected = false
                driveTestResult = .failure(message)
            }
        }
    }

    // Static (not instance methods) so they're safe to call from a
    // property initializer above, before `self` exists — see
    // selectedTelegramChat's doc comment.
    private static func computeFilteredTelegramChats() -> [TelegramChat] {
        PositionPolicy.filteredTelegramChats(AppSecrets.telegramChats, position: AppSettings.shared.position)
    }

    private static func initialSelectedTelegramChat() -> TelegramChatSelection {
        let chats = computeFilteredTelegramChats()
        let match: TelegramChat?
        if AppSettings.shared.position == "Кваліфікатор" {
            match = chats.first
        } else {
            match = chats.first {
                $0.chatId == AppSettings.shared.telegramChatId && $0.topicId == AppSettings.shared.telegramTopicId
            }
        }
        return match.map(TelegramChatSelection.chat) ?? .none
    }

    // Same "empty clears the setting" stance as the Kommo field below —
    // both start out unset on every fresh install.
    private func saveKommoSubdomain() {
        let trimmed = kommoSubdomain.trimmingCharacters(in: .whitespacesAndNewlines)
        AppSettings.shared.kommoSubdomain = trimmed.isEmpty ? nil : trimmed
        // Same "unverified edit invalidates the cached status" reasoning as
        // saveDriveFolderId above.
        AppSettings.shared.isKommoConnected = false
        kommoTestResult = nil
    }

    private func saveKommoApiToken() {
        let trimmed = kommoApiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        AppSettings.shared.kommoApiToken = trimmed.isEmpty ? nil : trimmed
        AppSettings.shared.isKommoConnected = false
        kommoTestResult = nil
    }

    private func testKommoConnection() {
        isTestingKommoConnection = true
        kommoTestResult = nil
        Task {
            let result = await KommoService.testConnection()
            isTestingKommoConnection = false
            switch result {
            case .success:
                AppSettings.shared.isKommoConnected = true
                kommoTestResult = .success("Доступ підключено")
            case .failure(let message):
                AppSettings.shared.isKommoConnected = false
                kommoTestResult = .failure(message)
            }
        }
    }
}
