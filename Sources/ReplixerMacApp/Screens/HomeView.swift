import SwiftUI
import Combine
import ReplixerMacCore

/// Phase 7.5 — Windows parity source: `HomeViewModel` (699 lines) +
/// `HomePage.xaml`, scoped down hard to what mac's pipeline actually
/// supports today. Recording here is fully automatic — `CallMonitor`
/// detects a call and `CallRecordingCoordinator` starts/stops it with no
/// human in the loop — so there's no manual start/stop button to wire
/// (Windows' `IdleCallViewModel.RecordManuallyCommand`/
/// `ActiveCallViewModel.StopCommand` assume a human can drive start/stop,
/// which mac's coordinator API doesn't expose), no call-confirmation dialog
/// (`CallDialogViewModel`), no report form (`CallReportViewModel` —
/// Phase 6/10-specific, not built), and no missed-calls tracking
/// (`MissedCallReportViewModel`/`MissedCallsViewModel` — Phase 10, not
/// built) to fold into "ОСТАННІ ЗАПИСИ". So this screen is just two things:
/// a live "is a call being recorded right now" status card, and the 4 most
/// recent `RecordingEntry` rows (no missed-call entries to interleave,
/// unlike Windows' `RecentActivity`).
struct HomeView: View {
    // Mirrors of ReplixerMacCore's two lock-protected snapshots — same
    // "local @State, refreshed via a plain NotificationCenter post"
    // pattern as SettingsView/RecordingsView, since ReplixerMacCore stays
    // SwiftUI-free by design.
    @State private var status = RecordingStatusStore.shared.status
    @State private var recentEntries: [RecordingEntry] = Array(RecordingHistory.shared.entries.prefix(4))
    @State private var now = Date()

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
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
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
        }
        .padding(.vertical, 6)
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
}
