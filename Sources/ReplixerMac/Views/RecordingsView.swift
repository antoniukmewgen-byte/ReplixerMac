import SwiftUI

struct RecordingsView: View {
    @EnvironmentObject var appVM: AppViewModel
    @State private var selectedID: UUID?
    @State private var searchText = ""

    var filtered: [Recording] {
        guard !searchText.isEmpty else { return appVM.recordings }
        let q = searchText.lowercased()
        return appVM.recordings.filter {
            $0.appName.lowercased().contains(q) ||
            $0.managerName.lowercased().contains(q) ||
            $0.fileName.lowercased().contains(q)
        }
    }

    var body: some View {
        NavigationSplitView {
            recordingsList
        } detail: {
            if let id = selectedID, let rec = appVM.recordings.first(where: { $0.id == id }) {
                RecordingDetailView(recording: rec)
                    .environmentObject(appVM)
            } else {
                emptyDetail
            }
        }
        .searchable(text: $searchText, prompt: "Пошук записів")
        .navigationTitle("Записи")
        .toolbar { toolbarContent }
        .frame(minWidth: 700, minHeight: 450)
    }

    // MARK: - List
    private var recordingsList: some View {
        List(filtered, selection: $selectedID) { rec in
            RecordingRow(recording: rec)
                .tag(rec.id)
                .contextMenu {
                    Button("Відкрити у Finder") { NSWorkspace.shared.selectFile(rec.filePath, inFileViewerRootedAtPath: "") }
                    Button("Повторити завантаження") {
                        Task { await appVM.retryUpload(recording: rec) }
                    }
                    Divider()
                    Button("Видалити", role: .destructive) { appVM.deleteRecording(rec) }
                }
        }
        .listStyle(.sidebar)
    }

    private var emptyDetail: some View {
        ContentUnavailableView(
            "Виберіть запис",
            systemImage: "waveform",
            description: Text("Деталі запису з'являться тут")
        )
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Text("\(appVM.recordings.count) записів")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }
}

// MARK: - Row
struct RecordingRow: View {
    let recording: Recording

    var body: some View {
        HStack(spacing: 10) {
            appIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(recording.appName)
                    .font(.headline)
                HStack {
                    Text(recording.managerName)
                    Text("·")
                    Text(durationText)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                Text(dateText)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            uploadBadge
        }
        .padding(.vertical, 2)
    }

    private var appIcon: some View {
        let iconName: String
        switch recording.appName {
        case "Telegram":    iconName = "paperplane.fill"
        case "Viber":       iconName = "phone.fill"
        case "WhatsApp":    iconName = "bubble.left.fill"
        default:            iconName = "headphones"
        }
        return Image(systemName: iconName)
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(appColor)
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var appColor: Color {
        switch recording.appName {
        case "Telegram":    return .blue
        case "Viber":       return .purple
        case "WhatsApp":    return .green
        default:            return .gray
        }
    }

    private var durationText: String {
        let t = Int(recording.durationSeconds)
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    private var dateText: String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: recording.createdAt)
    }

    @ViewBuilder
    private var uploadBadge: some View {
        switch recording.uploadState {
        case .pending:
            Image(systemName: "clock").foregroundStyle(.secondary)
        case .uploadingDrive, .uploadingTelegram:
            ProgressView().scaleEffect(0.7)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        }
    }
}

// MARK: - Detail
struct RecordingDetailView: View {
    let recording: Recording
    @EnvironmentObject var appVM: AppViewModel
    @State private var isPlaying = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                infoGrid
                actions
            }
            .padding(24)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(recording.appName)
                .font(.largeTitle.bold())
            Text(recording.managerName)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var infoGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 10) {
            GridRow {
                Label("Дата", systemImage: "calendar")
                    .foregroundStyle(.secondary)
                Text(formatted(recording.createdAt))
            }
            GridRow {
                Label("Тривалість", systemImage: "timer")
                    .foregroundStyle(.secondary)
                Text(durationFormatted)
            }
            GridRow {
                Label("Розмір", systemImage: "doc.fill")
                    .foregroundStyle(.secondary)
                Text(ByteCountFormatter.string(fromByteCount: recording.fileSizeBytes, countStyle: .file))
            }
            GridRow {
                Label("Завантаження", systemImage: "arrow.up.circle")
                    .foregroundStyle(.secondary)
                uploadStateBadge
            }
        }
        .padding()
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var actions: some View {
        HStack {
            Button("Показати у Finder") {
                NSWorkspace.shared.selectFile(recording.filePath, inFileViewerRootedAtPath: "")
            }
            .buttonStyle(.bordered)

            if recording.uploadState == .failed || recording.uploadState == .pending {
                Button("Повторити завантаження") {
                    Task { await appVM.retryUpload(recording: recording) }
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    @ViewBuilder
    private var uploadStateBadge: some View {
        switch recording.uploadState {
        case .pending:          Text("Очікування").foregroundStyle(.secondary)
        case .uploadingDrive:   Text("Drive…").foregroundStyle(.orange)
        case .uploadingTelegram: Text("Telegram…").foregroundStyle(.blue)
        case .done:             Text("✓ Завантажено").foregroundStyle(.green)
        case .failed:           Text("✗ Помилка").foregroundStyle(.red)
        }
    }

    private var durationFormatted: String {
        let t = Int(recording.durationSeconds)
        return String(format: "%d хв %02d с", t / 60, t % 60)
    }

    private func formatted(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .long
        f.timeStyle = .short
        return f.string(from: date)
    }
}
