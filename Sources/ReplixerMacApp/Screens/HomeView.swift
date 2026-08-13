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
        VStack(alignment: .leading, spacing: 12) {
            statusCard
            recentActivityCard
        }
        .padding(16)
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
        HStack(spacing: 12) {
            if status.isRecording {
                Image(systemName: "record.circle.fill")
                    .foregroundStyle(.red)
                    .font(.title2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(status.platform ?? "Дзвінок")
                        .font(.headline)
                    Text("Триває запис — \(elapsedTimeText)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            } else {
                Image(systemName: "waveform")
                    .foregroundStyle(.secondary)
                    .font(.title2)
                Text("Очікую дзвінок...")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            manualActionButton
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    // Phase 11.2 — Windows parity: `IdleCallViewModel.RecordManuallyCommand`/
    // `ActiveCallViewModel.StopCommand`. `CallRecordingCoordinator.appInstance`
    // is nil only in contexts this view never actually runs in (unit tests,
    // the headless PoC target) — the `if let` just avoids a force-unwrap
    // rather than guarding against a real runtime case.
    @ViewBuilder
    private var manualActionButton: some View {
        if status.isRecording {
            Button("Зупинити запис") {
                guard let coordinator = CallRecordingCoordinator.appInstance else { return }
                Task { await coordinator.manualStop() }
            }
            .buttonStyle(.bordered)
        } else {
            Button("Почати запис вручну") {
                startManually()
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
        VStack(alignment: .leading, spacing: 8) {
            Text("ОСТАННІ ЗАПИСИ")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundStyle(.secondary)

            if recentEntries.isEmpty {
                ContentUnavailableView(
                    "Записів ще немає",
                    systemImage: "waveform",
                    description: Text("Тут з'являться останні записи після першого дзвінка.")
                )
                .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 0) {
                    ForEach(recentEntries) { entry in
                        RecentActivityRow(entry: entry)
                        if entry.id != recentEntries.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
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
        }
        .padding(.vertical, 6)
        .alert("Не вдалося відновити чернетку", isPresented: Binding(
            get: { resumeAlertMessage != nil },
            set: { if !$0 { resumeAlertMessage = nil } }
        )) {
            Button("Гаразд", role: .cancel) { resumeAlertMessage = nil }
        } message: {
            Text(resumeAlertMessage ?? "")
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

    @ViewBuilder
    private var statusIcon: some View {
        switch entry.status {
        case .recording:
            Image(systemName: "record.circle.fill")
                .foregroundStyle(.red)
        case .saved:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case .draft:
            // Phase 11.3 — same icon/color choice as RecordingsView's
            // statusIcon, so the 4-row "ОСТАННІ ЗАПИСИ" preview on this
            // screen and the full history list read consistently.
            Image(systemName: "doc.badge.clock")
                .foregroundStyle(.yellow)
        }
    }
}
