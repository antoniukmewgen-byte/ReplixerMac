import SwiftUI
import AppKit
import Combine
import ReplixerMacCore

/// Phase 7.4 — Windows parity source: `RecordingsViewModel.cs` +
/// `RecordingItemView.xaml`. Scoped to what mac's `RecordingEntry` actually
/// tracks: platform, start time, status, duration, Drive link, Telegram
/// send state. Background retry already happens automatically via
/// `PendingUploadRetryService`, so there's no manual "retry now" action to
/// expose; no editable Telegram report either (Phase 10-specific concept
/// not built here).
///
/// Phase 11.3 update: mac *does* now have a `.draft` status (a call whose
/// report form was interrupted by a new call before being submitted, see
/// `RecordingStatus.draft`) — `RecordingRow` below surfaces a "Заповнити
/// звіт" button directly in the row, same intent as Windows' per-row
/// resume-draft button.
///
/// Phase 11.3 follow-up: all row actions (resume-draft, show-in-Finder,
/// open-on-Drive) are now always-visible icon buttons, matching Windows'
/// `RecordingItemView.xaml` row of buttons — no context menu, right-click
/// isn't discoverable enough to be the only way to reach these.
struct RecordingsView: View {
    // ReplixerMacCore stays headless/SwiftUI-free (Phase 7 architecture
    // split), so RecordingHistory can't be @ObservedObject — mirror its
    // thread-safe `entries` snapshot into local @State and refresh on the
    // plain NotificationCenter signal it posts after every mutation.
    @State private var entries: [RecordingEntry] = RecordingHistory.shared.entries

    private let didChangePublisher = NotificationCenter.default
        .publisher(for: RecordingHistory.didChangeNotification)
        .receive(on: DispatchQueue.main)

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView(
                    "Записів ще немає",
                    systemImage: "waveform",
                    description: Text("Тут з'являться записи після першого дзвінка.")
                )
            } else {
                List(entries) { entry in
                    RecordingRow(entry: entry)
                }
            }
        }
        .navigationTitle("Записи")
        .onReceive(didChangePublisher) { _ in
            entries = RecordingHistory.shared.entries
        }
    }
}

private struct RecordingRow: View {
    let entry: RecordingEntry

    // Phase 11.3 — surfaces `resumeDraft`'s non-`.started` outcomes (the
    // "started" case needs no feedback here: the report sheet just opens,
    // same as any other pending-report request driven by `ContentView`).
    @State private var resumeAlertMessage: String?

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .font(.title2)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.platform)
                    .font(.headline)
                HStack(spacing: 6) {
                    Text(entry.startedAt.formatted(date: .abbreviated, time: .shortened))
                    if entry.telegramMessageId != nil {
                        Image(systemName: "paperplane.fill")
                            .help("Надіслано в Telegram")
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if entry.status == .saved, let durationText = Self.durationFormatter.string(from: entry.callDuration) {
                Text(durationText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            // Phase 11.3 — the main way most drafts actually get resolved,
            // so it gets the prominent/labeled button style, unlike the
            // secondary Finder/Drive icon-only buttons below. Windows
            // parity: `RecordingItemView.xaml`'s always-visible resume-draft
            // button on a `.draft` row.
            if entry.status == .draft {
                Button {
                    resumeDraft()
                } label: {
                    Label("Заповнити звіт", systemImage: "square.and.pencil")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            // Phase 11.3 follow-up — visible counterpart of the old
            // context-menu "Показати у Finder" entry, same reasoning as the
            // draft-resume button above: right-click alone isn't
            // discoverable enough, Windows parity keeps this as a row icon
            // button.
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
        .padding(.vertical, 4)
        // Windows parity: `RecordingItemView.xaml`'s resume-draft button
        // surfacing `ResumeDraftAsync`'s failure cases via a message box —
        // mac's equivalent is this alert, driven by `resumeDraft()` below.
        .alert("Не вдалося відновити чернетку", isPresented: Binding(
            get: { resumeAlertMessage != nil },
            set: { if !$0 { resumeAlertMessage = nil } }
        )) {
            Button("Гаразд", role: .cancel) { resumeAlertMessage = nil }
        } message: {
            Text(resumeAlertMessage ?? "")
        }
    }

    // Phase 11.3 — Windows parity: `RecordingsViewModel.ResumeDraftCommand`.
    // `CallRecordingCoordinator.appInstance` nil-check mirrors the same
    // idiom `HomeView.startManually()` uses.
    private func resumeDraft() {
        guard let coordinator = CallRecordingCoordinator.appInstance else { return }
        let id = entry.id
        Task {
            switch await coordinator.resumeDraft(entryID: id) {
            case .started, .interrupted:
                // .started: the report sheet opens on its own via
                // ContentView's CallReportRequestStore observation, nothing
                // more to do here. .interrupted: another call bumped this
                // resumed form before submission — the entry just goes back
                // to `.draft`, resumable again later, same as the first
                // interruption; not worth a separate alert for what's really
                // the normal draft state.
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
            Image(systemName: "doc.badge.clock")
                .foregroundStyle(.yellow)
        }
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }()
}
