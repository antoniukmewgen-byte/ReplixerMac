import SwiftUI
import AppKit
import ReplixerMacCore

/// Phase 7.3 — first real (non-placeholder) screen. Windows parity source:
/// `SettingsViewModel` (83 lines, "the simplest screen, a thin proxy over
/// `AppSettings`") — but scoped down to what mac `AppSettings` actually
/// persists today. Windows exposes `IsAutoStartEnabled`,
/// `IsNotificationsEnabled`, `WorkDayStart`/`WorkDayEnd` here too; mac
/// `AppSettings` deliberately has none of those fields yet (its own doc
/// comment: don't add a field before the phase that gives it real behavior
/// — autostart needs Phase 8's `SMAppService`, notifications need a real
/// notification-sending path). So this screen doesn't grow fake toggles for
/// them either; it only surfaces what's real right now: `managerName`.
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

    var body: some View {
        Form {
            Section("Профіль") {
                TextField("Ім'я менеджера", text: $managerName)
                    .onSubmit(saveManagerName)
                    // Covers focus-loss edits too (e.g. clicking away
                    // instead of pressing Return) — onSubmit alone would
                    // miss those.
                    .onChange(of: managerName) { _, _ in saveManagerName() }
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
}

#Preview {
    SettingsView()
}
