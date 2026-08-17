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
/// see the "Запуск" section below, and Phase 10.1c gave `WorkDayStart`/
/// `WorkDayEnd` one too (`KommoService`'s working-hours processing-speed
/// field — see the "Робочий час" section). `IsNotificationsEnabled` still
/// has no real behavior to drive (no notification-sending path exists yet),
/// so that one stays cut for now, same don't-add-a-field-before-the-phase-
/// that-uses-it stance.
///
/// Telegram's `telegramChatId`/`TopicId` and Google Drive's
/// `googleDriveFolderId` get their own UI on `ProfileView` (Phase 7.6), not
/// this screen. Revealing the settings file in Finder keeps the raw JSON
/// discoverable without a picker for anything not exposed there. (Telegram's
/// `apiId`/`apiHash` and Google Drive's service-account credential aren't
/// settings at all anymore — they're build-time constants,
/// `AppSecrets.telegramApiId`/`telegramApiHash`/`googleServiceAccountJson`,
/// matching Windows.)
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

    // Phase 10.1c: feeds KommoService's "робочий час" processing-speed calc
    // (see its doc comment). AppSettings stores minutes-since-midnight
    // (Int); DatePicker wants a Date, so these two @State vars are built
    // from/collapsed back to that Int via workDayDate(fromMinutes:)/
    // minutesSinceMidnight(from:) below — same local-@State-mirror pattern
    // as every other field on this screen, just with an extra unit
    // conversion at the boundary.
    @State private var workDayStart: Date = SettingsView.workDayDate(fromMinutes: AppSettings.shared.workDayStartMinutes)
    @State private var workDayEnd: Date = SettingsView.workDayDate(fromMinutes: AppSettings.shared.workDayEndMinutes)

    var body: some View {
        Form {
            // Design-only: every Section below now takes a `Label` title
            // instead of a bare string — small colorful glyph next to each
            // section heading, same "each area gets its own icon" idiom the
            // sidebar (`ContentView.sidebarRow`) already uses, so Settings
            // reads consistently with the rest of the redesigned app. No
            // field, onChange handler, or persistence call below changed.
            Section {
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
            } header: {
                Label("Профіль", systemImage: "person.crop.circle.fill")
            }

            Section {
                Toggle("Запускати ReplixerMac при вході в систему", isOn: $isAutoStartEnabled)
                    .onChange(of: isAutoStartEnabled) { _, newValue in setAutoStart(newValue) }

                if let autoStartError {
                    Label(autoStartError, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(Theme.Status.warning)
                        .font(.caption)
                }
            } header: {
                Label("Запуск", systemImage: "power")
            }

            Section {
                DatePicker("Початок", selection: $workDayStart, displayedComponents: .hourAndMinute)
                    .onChange(of: workDayStart) { _, newValue in
                        AppSettings.shared.workDayStartMinutes = Self.minutesSinceMidnight(from: newValue)
                    }
                DatePicker("Кінець", selection: $workDayEnd, displayedComponents: .hourAndMinute)
                    .onChange(of: workDayEnd) { _, newValue in
                        AppSettings.shared.workDayEndMinutes = Self.minutesSinceMidnight(from: newValue)
                    }
                Text("Використовується Kommo-полем \"Швидкість обробки в робочий час\" — межі робочого дня клієнта в його місцевому часовому поясі (для українських номерів вікно зсувається на +7 год).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Label("Робочий час", systemImage: "clock.fill")
            }

            Section {
                LabeledContent("Файл налаштувань") {
                    Text(AppSettings.store.url.path)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button("Показати у Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppSettings.store.url])
                }
            } header: {
                Label("Дані застосунку", systemImage: "externaldrive.fill")
            }

            // Windows parity: SettingsViewModel.AppVersion ("v{major.minor.build}",
            // bound in the "ПРО ДОДАТОК" card at the bottom of SettingsPage.xaml) —
            // this was the one field flagged as missing after the Phase 9.1 CI
            // release-automation work landed, since there was previously no way
            // to confirm from inside the running app which build actually
            // installed. Reads straight from Info.plist's CFBundleShortVersionString
            // (same value TelegramUploadService.appVersion already reads for its
            // upload-caption footer) rather than duplicating the version anywhere
            // — Scripts/prepare-release.sh's text-splice is the one place that
            // ever writes it, so this can only ever show what's actually running.
            Section {
                HStack(spacing: 12) {
                    Image(nsImage: NSApplication.shared.applicationIconImage)
                        .resizable()
                        .frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("ReplixerMac")
                            .font(.headline)
                        Text("v\(Self.appVersion)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            } header: {
                Label("Про застосунок", systemImage: "info.circle.fill")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Налаштування")
    }

    // Falls back to "0.1.0-poc" (same sentinel TelegramUploadService.appVersion
    // already uses) if Info.plist's key is ever missing — should only happen
    // running a raw SPM executable outside a real .app bundle, never in a
    // release build.
    private static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1.0-poc"
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

    // `DatePicker(displayedComponents: .hourAndMinute)` still needs a full
    // `Date`, not just an hour/minute pair — anchors both onto today's date
    // at midnight local time (the calendar day itself is thrown away by
    // minutesSinceMidnight below, only hour/minute round-trip).
    private static func workDayDate(fromMinutes minutes: Int) -> Date {
        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: Date())
        return calendar.date(byAdding: .minute, value: minutes, to: startOfToday) ?? startOfToday
    }

    private static func minutesSinceMidnight(from date: Date) -> Int {
        let calendar = Calendar.current
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}
