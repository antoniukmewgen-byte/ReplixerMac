import SwiftUI
import AppKit
import Combine
import ReplixerMacCore

/// Phase 7.5 (manual start/stop + confirm dialog added Phase 11.1/11.2) —
/// Windows parity source: `HomeViewModel` (699 lines) + `HomePage.xaml`,
/// still scoped down from it: call-confirmation now exists
/// (`CallConfirmRequestStore`/`CallConfirmView`, wired from `CallMonitor` in
/// `ReplixerMacApp`'s `AppDelegate` — Windows parity: `CallDialogViewModel`)
/// and manual start/stop now exists (the button below, Windows parity:
/// `IdleCallViewModel.RecordManuallyCommand`/`ActiveCallViewModel
/// .StopCommand`), and report form draft/interrupt recovery now exists too
/// (Windows parity: `CallReportViewModel.CaptureDraft`/`RecordingStatus
/// .Draft` — Phase 11.3). `RecentActivityRow` below mirrors
/// `RecordingsView`'s `RecordingRow` icon-button row (resume-draft/Finder/
/// Drive) for consistency between the 4-row preview here and the full
/// history list — same Windows parity source (`RecordingItemView.xaml`)
/// either way. Still no per-entry retry action (Phase 11.4), and no
/// missed-calls tracking (`MissedCallReportViewModel`/`MissedCallsViewModel`
/// — Phase 10, not built) to fold into "ОСТАННІ ЗАПИСИ". So this screen is:
/// a live "is a call being recorded right now" status card (now with a
/// manual start/stop button), and the 4 most recent `RecordingEntry` rows
/// (no missed-call entries to interleave, unlike Windows' `RecentActivity`).
struct HomeView: View {
    // Mirrors of ReplixerMacCore's two lock-protected snapshots — same
    // "local @State, refreshed via a plain NotificationCenter post"
    // pattern as SettingsView/RecordingsView, since ReplixerMacCore stays
    // SwiftUI-free by design.
    @State private var status = RecordingStatusStore.shared.status
    @State private var recentEntries: [RecordingEntry] = Array(RecordingHistory.shared.entries.prefix(4))
    @State private var now = Date()
    // Phase 11.2: set when `manualStart()` reports something other than
    // `.started`/`.alreadyRecording` — drives the alert below. `nil` means
    // "no alert showing", matching the `Binding`-from-Optional pattern used
    // elsewhere in this app (e.g. ContentView's sheet(item:) bindings).
    @State private var manualStartError: String?

    private let statusPublisher = NotificationCenter.default
        .publisher(for: RecordingStatusStore.didChangeNotification)
        .receive(on: DispatchQueue.main)
    private let historyPublisher = NotificationCenter.default
        .publisher(for: RecordingHistory.didChangeNotification)
        .receive(on: DispatchQueue.main)
    // Drives the elapsed-time readout in `statusCard` while a call is being
    // recorded — Windows-parity source: `ActiveCallViewModel`'s
    // `DispatcherTimer` ticking `ElapsedTime` every second.
    private let elapsedTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.item) {
            statusCard
            recentActivityCard
        }
        .padding(Theme.Spacing.screen)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Головна")
        .onReceive(statusPublisher) { _ in status = RecordingStatusStore.shared.status }
        .onReceive(historyPublisher) { _ in recentEntries = Array(RecordingHistory.shared.entries.prefix(4)) }
        .onReceive(elapsedTimer) { date in now = date }
        // Phase 11.2 — Windows parity: `ErrorReporter.Report("RECORDING_START", ...)`
        // inside `HomeViewModel.StartRecording`'s failure branch, surfaced
        // here as a plain alert since mac has no error-reporting bot yet
        // (Phase 5 of the gap list — this alert is the whole notification,
        // not just a supplement to one).
        .alert(
            "Не вдалося почати запис",
            isPresented: Binding(
                get: { manualStartError != nil },
                set: { isPresented in if !isPresented { manualStartError = nil } }
            ),
            presenting: manualStartError
        ) { _ in
            Button("Гаразд", role: .cancel) { manualStartError = nil }
        } message: { errorText in
            Text(errorText)
        }
    }

    private var statusCard: some View {
        HStack(spacing: 16) {
            ZStack(alignment: .bottomTrailing) {
                IconBadge(
                    systemImage: status.isRecording ? "record.circle.fill" : "waveform",
                    tint: status.isRecording ? Theme.Status.recording : .secondary,
                    size: 52
                )
                if status.isRecording {
                    PulsingDot(size: 9)
                        .offset(x: 3, y: 3)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(status.isRecording ? (status.platform ?? "Дзвінок") : "Очікую дзвінок...")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(status.isRecording ? .primary : .secondary)

                if status.isRecording {
                    Text("Триває запис — \(elapsedTimeText)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text("Запис розпочнеться автоматично, щойно з'явиться дзвінок")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                missedCallButton
                manualActionButton
            }
        }
        .cardSurface()
    }

    // Phase 11.5 — Windows parity: `HomeViewModel.MissedCallCommand`, always
    // available regardless of whether a call is currently being recorded
    // (a missed call is, by definition, a call that never became a
    // recording) — unlike manualActionButton, this doesn't switch on
    // `status.isRecording`. Precisely *because* this stays clickable during
    // an active recording, `MissedCallReportRequestStore`'s pending request
    // is folded into `ContentView`'s single `ActiveCallSheet` enum rather
    // than driving its own independent `.sheet(item:)` — see that type's
    // doc comment for why two independent sheets on one view is the exact
    // bug class Phase 11.3 already had to fix once.
    private var missedCallButton: some View {
        Button {
            MissedCallReportRequestStore.shared.open()
        } label: {
            Label("Не додзвонився", systemImage: "phone.down")
        }
        .buttonStyle(.bordered)
    }

    // Phase 11.2 — Windows parity: `IdleCallViewModel.RecordManuallyCommand`/
    // `ActiveCallViewModel.StopCommand`. `CallRecordingCoordinator.appInstance`
    // is nil only in contexts this view never actually runs in (unit tests,
    // the headless PoC target) — the `if let` just avoids a force-unwrap
    // rather than guarding against a real runtime case.
    @ViewBuilder
    private var manualActionButton: some View {
        if status.isRecording {
            Button {
                guard let coordinator = CallRecordingCoordinator.appInstance else { return }
                Task { await coordinator.manualStop() }
            } label: {
                Label("Зупинити запис", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .tint(.red)
        } else {
            Button {
                startManually()
            } label: {
                Label("Почати запис вручну", systemImage: "record.circle")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func startManually() {
        guard let coordinator = CallRecordingCoordinator.appInstance else { return }
        Task {
            switch await coordinator.manualStart() {
            case .started, .alreadyRecording:
                break
            case .noMessengerRunning:
                manualStartError = "Не знайшов жодного підтримуваного месенджера (Telegram/WhatsApp/Viber/Ringostat) серед запущених застосунків. Відкрий один із них і спробуй ще раз."
            case .failed:
                manualStartError = "Не вдалося запустити запис. Перевір дозвіл мікрофона в Налаштуваннях системи."
            }
        }
    }

    private var elapsedTimeText: String {
        guard let startedAt = status.startedAt else { return "00:00" }
        let elapsed = max(0, now.timeIntervalSince(startedAt))
        return Self.elapsedFormatter.string(from: elapsed) ?? "00:00"
    }

    private var recentActivityCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ОСТАННІ ЗАПИСИ")
                .sectionCaptionStyle()

            if recentEntries.isEmpty {
                ContentUnavailableView(
                    "Записів ще немає",
                    systemImage: "waveform",
                    description: Text("Тут з'являться останні записи після першого дзвінка.")
                )
                .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 2) {
                    ForEach(recentEntries) { entry in
                        RecentActivityRow(entry: entry)
                    }
                }
            }
        }
        .cardSurface()
    }

    private static let elapsedFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }()
}

private struct RecentActivityRow: View {
    let entry: RecordingEntry

    // Phase 11.3 follow-up — same purpose as RecordingRow's identically
    // named property: surfaces resumeDraft()'s non-.started outcomes.
    @State private var resumeAlertMessage: String?

    // Phase 11.4 — same purpose as RecordingRow's identically named
    // property: surfaces editReport()'s non-.succeeded/.interrupted
    // outcomes.
    @State private var editAlertMessage: String?

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.platform)
                    .font(.subheadline)
                    .fontWeight(.medium)
                Text(entry.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()

            // Phase 11.3 follow-up — mirrors RecordingsView's RecordingRow
            // icon-button row so the home screen's preview offers the same
            // actions as the full history list, not just a read-only glance.
            if entry.status == .draft {
                Button {
                    resumeDraft()
                } label: {
                    Label("Заповнити звіт", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if let filePath = entry.filePath, FileManager.default.fileExists(atPath: filePath) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: filePath)])
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Показати у Finder")
            }

            if let driveUrlString = entry.driveUrl, let driveUrl = URL(string: driveUrlString) {
                Link(destination: driveUrl) {
                    Image(systemName: "arrow.up.right.square")
                }
                .help("Відкрити на Google Drive")
            }

            // Phase 11.4 — mirrors RecordingsView's RecordingRow edit
            // button, same reasoning as the resume-draft/Finder/Drive
            // buttons above.
            if entry.telegramMessageId != nil {
                Button {
                    editReport()
                } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help("Редагувати звіт")
            }
        }
        .cardRow()
        .alert("Не вдалося відновити чернетку", isPresented: Binding(
            get: { resumeAlertMessage != nil },
            set: { if !$0 { resumeAlertMessage = nil } }
        )) {
            Button("Гаразд", role: .cancel) { resumeAlertMessage = nil }
        } message: {
            Text(resumeAlertMessage ?? "")
        }
        // Phase 11.4 — same idiom, driven by editReport() below.
        .alert("Не вдалося оновити звіт", isPresented: Binding(
            get: { editAlertMessage != nil },
            set: { if !$0 { editAlertMessage = nil } }
        )) {
            Button("Гаразд", role: .cancel) { editAlertMessage = nil }
        } message: {
            Text(editAlertMessage ?? "")
        }
    }

    // Phase 11.3 follow-up — identical logic to RecordingsView's
    // RecordingRow.resumeDraft(); duplicated rather than shared since each
    // is a small private view-local helper, same pattern already used
    // between the two files' statusIcon switches.
    private func resumeDraft() {
        guard let coordinator = CallRecordingCoordinator.appInstance else { return }
        let id = entry.id
        Task {
            switch await coordinator.resumeDraft(entryID: id) {
            case .started, .interrupted:
                break
            case .notFound:
                resumeAlertMessage = "Цей запис більше не знайдено в історії."
            case .fileMissing:
                resumeAlertMessage = "Файл запису відсутній на диску — відновити чернетку неможливо."
            case .reportAlreadyOpen:
                resumeAlertMessage = "Зараз відкрита інша форма звіту. Заверши її й спробуй ще раз."
            }
        }
    }

    // Phase 11.4 — identical logic to RecordingsView's RecordingRow
    // .editReport(); duplicated for the same reason resumeDraft() is above.
    private func editReport() {
        guard let coordinator = CallRecordingCoordinator.appInstance else { return }
        let id = entry.id
        Task {
            switch await coordinator.editReport(entryID: id) {
            case .succeeded, .interrupted:
                break
            case .notFound:
                editAlertMessage = "Цей запис більше не знайдено в історії."
            case .noTelegramMessage:
                editAlertMessage = "Цей запис ще не надсилався в Telegram — редагувати нічого."
            case .reportAlreadyOpen:
                editAlertMessage = "Зараз відкрита інша форма звіту. Заверши її й спробуй ще раз."
            case .failed(let reason):
                editAlertMessage = reason
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch entry.status {
        case .recording:
            Image(systemName: "record.circle.fill")
                .foregroundStyle(Theme.Status.recording)
        case .saved:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.Status.saved)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Theme.Status.warning)
        case .draft:
            // Phase 11.3 — same icon/color choice as RecordingsView's
            // statusIcon, so the 4-row "ОСТАННІ ЗАПИСИ" preview on this
            // screen and the full history list read consistently.
            Image(systemName: "doc.badge.clock")
                .foregroundStyle(Theme.Status.draft)
        }
    }
}
