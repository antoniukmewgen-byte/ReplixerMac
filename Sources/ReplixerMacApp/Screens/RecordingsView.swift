import SwiftUI
import AppKit
import Combine
import ReplixerMacCore

/// Phase 7.4 — Windows parity source: `RecordingsViewModel.cs` +
/// `RecordingItemView.xaml`. Scoped to what mac's `RecordingEntry` actually
/// tracks: platform, start time, status, duration, Drive link, Telegram
/// send state. Windows' per-row retry/resume-draft/edit-report buttons stay
/// out — mac has no `.draft` status and no editable Telegram report (both
/// Phase 6/10-specific concepts not built here); background retry already
/// happens automatically via `PendingUploadRetryService`, so there's no
/// "retry now" action to expose either.
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

            if let driveUrlString = entry.driveUrl, let driveUrl = URL(string: driveUrlString) {
                Link(destination: driveUrl) {
                    Image(systemName: "arrow.up.right.square")
                }
                .help("Відкрити на Google Drive")
            }
        }
        .padding(.vertical, 4)
        .contextMenu {
            if let filePath = entry.filePath, FileManager.default.fileExists(atPath: filePath) {
                Button("Показати у Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: filePath)])
                }
            }
            if let driveUrlString = entry.driveUrl, let driveUrl = URL(string: driveUrlString) {
                Button("Відкрити на Google Drive") {
                    NSWorkspace.shared.open(driveUrl)
                }
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
        }
    }

    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }()
}

#Preview {
    RecordingsView()
}
