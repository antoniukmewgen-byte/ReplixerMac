import SwiftUI

// Popover shown when user clicks the menu bar icon.
struct MenuBarView: View {
    @EnvironmentObject var appVM: AppViewModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(spacing: 0) {
            statusHeader
            Divider()
            actionButtons
        }
        .frame(width: 280)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Status header
    private var statusHeader: some View {
        HStack(spacing: 12) {
            statusIcon
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle)
                    .font(.headline)
                    .foregroundStyle(statusColor)
                if let session = appVM.activeSession {
                    Text("\(session.appName) · \(durationString)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Моніторинг активний")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding()
    }

    private var statusIcon: some View {
        ZStack {
            Circle()
                .fill(statusColor.opacity(0.2))
                .frame(width: 40, height: 40)
            Image(systemName: appVM.activeSession != nil ? "record.circle.fill" : "waveform")
                .font(.title2)
                .foregroundStyle(statusColor)
                .symbolEffect(.pulse, isActive: appVM.activeSession != nil)
        }
    }

    private var statusTitle: String {
        appVM.activeSession != nil ? "Запис дзвінку" : "Очікування"
    }

    private var statusColor: Color {
        appVM.activeSession != nil ? .red : .green
    }

    private var durationString: String {
        let t = Int(appVM.recordingDuration)
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    // MARK: - Action buttons
    private var actionButtons: some View {
        VStack(spacing: 0) {
            MenuButton(icon: "list.bullet.clipboard", label: "Записи (\(appVM.recordings.count))") {
                openWindow(id: "recordings")
            }
            MenuButton(icon: "gear", label: "Налаштування") {
                openWindow(id: "settings")
            }
            Divider().padding(.vertical, 4)
            MenuButton(icon: "power", label: "Вийти", role: .destructive) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Reusable menu button
struct MenuButton: View {
    let icon: String
    let label: String
    var role: ButtonRole? = nil
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 20)
                Text(label)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isHovered ? Color.accentColor.opacity(0.15) : Color.clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(role == .destructive ? Color.red : Color.primary)
        .onHover { isHovered = $0 }
    }
}
