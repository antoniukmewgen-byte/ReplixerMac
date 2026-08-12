import SwiftUI
import AppKit
import ReplixerMacCore

/// Phase 7.3 — first real (non-placeholder) screen. Windows parity source:
/// `SettingsViewModel` (83 lines, "the simplest screen, a thin proxy over
/// `AppSettings`") — but scoped down to what mac `AppSettings` actually
/// persists today. Windows exposes `IsAutoStartEnabled`,
/// `IsNotificationsEnabled`, `WorkDayStart`/`WorkDayEnd` here too; mac
/// `AppSettings` deliberately had none of those fields until Phase 8 gave
/// `IsAutoStartEnabled` a real backend (`AutoStartManager`/`SMAppService`) —
/// see the "Запуск" section below. `IsNotificationsEnabled`/`WorkDayStart`/
/// `WorkDayEnd` still have no real behavior to drive (no notification-
/// sending path exists yet), so those stay cut for now, same
/// don't-add-a-field-before-the-phase-that-uses-it stance.
///
/// Telegram/Google Drive credentials (`telegramApiId/Hash`, `telegramChatId`
/// /`TopicId`, `googleServiceAccountPath`, `googleDriveFolderId`) stay
/// hand-edit-JSON-only per `AppSettings`'s existing policy — their own UI is
/// Phase 4/5 scope, not this screen. Revealing the settings file in Finder
/// keeps that path discoverable without a picker.
struct SettingsView: View {
    // AppSettings is a plain class, not an ObservableObject — ReplixerMacCore
    // stays headless/SwiftUI-free by design (Phase 7 architecture split), so
    // this view can't just @ObservedObject/bind straight into the model. It
    // mirrors the value in local @State and writes back explicitly instead.
    @State private var managerName: String = AppSettings.shared.managerName
    // Phase 10.0: Windows parity — Менеджер/Діагност/Кваліфікатор gates
    // which call-report fields are shown (`PositionPolicy`) and whether/how
    // long a call must run before it's sent to Telegram at all
    // (`PositionPolicy.shouldSkipTelegram`). Picker over free text since
    // the value has to exactly match one of PositionPolicy's three string
    // cases — freeform entry could silently fall through its `default`
    // case and behave like an unrecognized role.
    @State private var position: String = AppSettings.shared.position
    // Phase 8.2: seeded from AppSettings (last-known intent), not from
    // AutoStartManager.isEnabled (ground truth) — this Form should reflect
    // "what the user asked for" immediately on screen without waiting on a
    // SMAppService round-trip, same instant-feedback stance every other
    // field on this screen already takes. autoStartError surfaces a thrown
    // registration failure inline rather than silently reverting the
    // toggle with no explanation.
    @State private var isAutoStartEnabled: Bool = AppSettings.shared.isAutoStartEnabled
    @State private var autoStartError: String?

    var body: some View {
        Form {
            Section("Профіль") {
                TextField("Ім'я менеджера", text: $managerName)
                    .onSubmit(saveManagerName)
                    // Covers focus-loss edits too (e.g. clicking away
                    // instead of pressing Return) — onSubmit alone would
                    // miss those.
                    .onChange(of: managerName) { _, _ in saveManagerName() }

                Picker("Роль", selection: $position) {
                    ForEach(CallReportData.positions, id: \.self) { option in
                        Text(option).tag(option)
                    }
                }
                .onChange(of: position) { _, newValue in
                    AppSettings.shared.position = newValue
                }
            }

            Section("Запуск") {
                Toggle("Запускати ReplixerMac при вході в систему", isOn: $isAutoStartEnabled)
                    .onChange(of: isAutoStartEnabled) { _, newValue in setAutoStart(newValue) }

                if let autoStartError {
                    Label(autoStartError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }

            Section("Дані застосунку") {
                LabeledContent("Файл налаштувань") {
                    Text(AppSettings.store.url.path)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button("Показати у Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppSettings.store.url])
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Налаштування")
    }

    // Empty/whitespace-only names are silently rejected rather than saved —
    // an empty managerName would produce garbled recording filenames
    // (FileNaming's `{Manager}_{Platform}_...` pattern), and there's no
    // separate validation UI at this scope to explain why.
    private func saveManagerName() {
        let trimmed = managerName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        AppSettings.shared.managerName = trimmed
    }

    // Registers/unregisters with launchd first, and only writes
    // AppSettings.isAutoStartEnabled if that succeeds — so a thrown
    // SMAppService error doesn't leave the persisted setting claiming a
    // state that isn't actually true on disk. On failure, the toggle is
    // snapped back to the last-known-good value rather than left showing
    // whatever the user just clicked.
    private func setAutoStart(_ enabled: Bool) {
        autoStartError = nil
        do {
            try AutoStartManager.setEnabled(enabled)
            AppSettings.shared.isAutoStartEnabled = enabled
        } catch {
            autoStartError = "Не вдалося змінити автозапуск: \(error)"
            isAutoStartEnabled = AppSettings.shared.isAutoStartEnabled
        }
    }
}
