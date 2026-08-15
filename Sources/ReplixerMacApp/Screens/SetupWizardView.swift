import SwiftUI
import ReplixerMacCore

/// Phase 7.7, rebuilt Phase 7.8 — first-launch welcome/setup wizard. Windows
/// parity source: `SetupViewModel`/`SetupWindow.xaml` (426/1140 lines) —
/// sequential cards for manager name, Google Drive, Kommo CRM, and Telegram,
/// each with its own "Обов'язково"/"Необов'язково · можна налаштувати
/// пізніше" framing and its own non-blocking "Перевірити з'єднання"/
/// "Авторизувати" button.
///
/// Still narrower than Windows in two specific, deliberate ways:
/// - **No Position picker.** Unlike Windows (where Position lives only in
///   this wizard + Profile), mac's `Position` already has a real home —
///   `SettingsView`'s "Профіль" section (`Picker` over
///   `CallReportData.positions`) — so duplicating it here would just be a
///   second, easier-to-desync copy of the same setting. Defaults to
///   "Менеджер" (`AppSettings.position`'s own default) until changed there.
/// - **No Google Sheets card.** Sheets has no mac backend at all yet (no
///   `GoogleSheetsUploadService`, no settings fields) — Phase 10 scope, not
///   this feature. Windows' Sheets card has no mac equivalent to show.
///
/// Google Drive / Kommo / Telegram test/authorize logic is NOT duplicated
/// here — Drive and Kommo reuse the exact same `CheckOutcome`-shaped
/// services `ProfileView` already calls (`GoogleDriveFolderAccessSmokeTest
/// .check()`/`KommoService.testConnection()`), and Telegram reuses the
/// shared `TelegramAuthSection` view, so a value saved/verified here and one
/// saved/verified later in Profile can never drift apart.
struct SetupWizardView: View {
    /// Called once the user taps "Почати роботу" — `ContentView` uses this
    /// to dismiss the sheet, rather than this view reaching into
    /// presentation state it doesn't own.
    var onFinish: () -> Void

    @State private var managerName: String = AppSettings.shared.managerName

    // Google Drive — same fields/flow as ProfileView's Drive section.
    @State private var driveFolderId: String =
        GoogleDriveFolderId.sanitize(AppSettings.shared.googleDriveFolderId ?? "")
    @State private var isTestingDriveConnection = false
    @State private var driveTestResult: GoogleDriveFolderAccessSmokeTest.CheckOutcome?

    // Kommo CRM — same fields/flow as ProfileView's Kommo section.
    @State private var kommoSubdomain: String = AppSettings.shared.kommoSubdomain ?? ""
    @State private var kommoApiToken: String = AppSettings.shared.kommoApiToken ?? ""
    @State private var isTestingKommoConnection = false
    @State private var kommoTestResult: KommoService.CheckOutcome?

    private var trimmedName: String {
        managerName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                IconBadge(systemImage: "waveform.circle.fill", tint: .accentColor, size: 56)
                Text("Ласкаво просимо до ReplixerMac")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .padding(.top, 8)
                Text("Заповни те, що потрібно зараз — решту завжди можна донастроїти пізніше на сторінці «Профіль».")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 12)

            Form {
                Section {
                    TextField("Ім'я менеджера", text: $managerName)
                        .onSubmit(finish)
                } header: {
                    Label("Профіль", systemImage: "person.crop.circle.fill")
                } footer: {
                    Text("Обов'язково — використовується в назві кожного запису дзвінка.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextField("ID теки Google Drive", text: $driveFolderId)

                    Button {
                        testDriveConnection()
                    } label: {
                        if isTestingDriveConnection {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Перевірити з'єднання")
                        }
                    }
                    .disabled(isTestingDriveConnection || driveFolderId.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

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
                } footer: {
                    Text("Необов'язково · можна налаштувати пізніше на сторінці «Профіль».")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    TextField("Subdomain (напр. myaccount)", text: $kommoSubdomain)
                    SecureField("API токен", text: $kommoApiToken)

                    Button {
                        testKommoConnection()
                    } label: {
                        if isTestingKommoConnection {
                            ProgressView().controlSize(.small)
                        } else {
                            Text("Перевірити з'єднання")
                        }
                    }
                    .disabled(isTestingKommoConnection || kommoSubdomain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || kommoApiToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

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
                } footer: {
                    Text("Необов'язково · можна налаштувати пізніше на сторінці «Профіль».")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    TelegramAuthSection()
                    Text("Чат призначення обирається окремо на сторінці «Профіль» після авторизації.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Label("Telegram", systemImage: "paperplane.fill")
                } footer: {
                    Text("Необов'язково · можна налаштувати пізніше на сторінці «Профіль».")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()
                Button("Почати роботу", action: finish)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(trimmedName.isEmpty)
            }
            .padding(20)
        }
        .frame(width: 520, height: 640)
        .onAppear {
            if let sanitized = GoogleDriveFolderId.sanitizedFromSettings(), sanitized != driveFolderId {
                driveFolderId = sanitized
            }
            if AppSettings.shared.isDriveConnected, !driveFolderId.isEmpty {
                driveTestResult = .success("Доступ підключено")
            }
            if AppSettings.shared.isKommoConnected, !kommoSubdomain.isEmpty {
                kommoTestResult = .success("Доступ підключено")
            }
        }
    }

    private func testDriveConnection() {
        // Save-then-test, same ordering as ProfileView's Drive section —
        // the smoke test itself always reads the folder id straight out of
        // AppSettings (GoogleDriveFolderId.sanitizedFromSettings()), not
        // from this text field, so a not-yet-saved edit would otherwise
        // silently test the *previous* value.
        let sanitized = GoogleDriveFolderId.sanitize(driveFolderId)
        if sanitized != driveFolderId {
            driveFolderId = sanitized
        }
        AppSettings.shared.googleDriveFolderId = sanitized.isEmpty ? nil : sanitized
        AppSettings.shared.isDriveConnected = false

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

    private func testKommoConnection() {
        let trimmedSubdomain = kommoSubdomain.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = kommoApiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        AppSettings.shared.kommoSubdomain = trimmedSubdomain.isEmpty ? nil : trimmedSubdomain
        AppSettings.shared.kommoApiToken = trimmedToken.isEmpty ? nil : trimmedToken
        AppSettings.shared.isKommoConnected = false

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

    // Windows parity (`SetupViewModel.Finish()`): manager name is the only
    // field that MUST be filled in to leave this screen — every other
    // section here is opt-in and already self-saves as its own fields are
    // edited/tested above (unlike Windows, which defers all of those writes
    // to this one moment), so there's nothing conditional left to do here.
    private func finish() {
        guard !trimmedName.isEmpty else { return }
        AppSettings.shared.managerName = trimmedName
        AppSettings.shared.isSetupComplete = true
        onFinish()
    }
}
