import SwiftUI
import ReplixerMacCore

/// Phase 11.5 — replaces the Phase 7.2 placeholder now that the missed-call
/// Kommo delivery backend exists (`MissedCallHistory`/
/// `MissedCallDeliveryService`, see those types' doc comments). Windows
/// parity source: `MissedCallsViewModel.cs` + `MissedCallItemView.xaml`,
/// scoped to what mac's `MissedCallEntry` actually tracks — no Sheets
/// column/processing-speed readout (no Sheets leg at all here, see
/// `MissedCallDeliveryService`'s doc comment), no manual "retry now" action
/// (background delivery already retries every 10s via
/// `MissedCallDeliveryService`, same reasoning `RecordingsView` gives for
/// not exposing one either).
struct MissedCallsView: View {
    // ReplixerMacCore stays headless/SwiftUI-free, so MissedCallHistory
    // can't be @ObservedObject — same "local @State mirror, refreshed on
    // NotificationCenter post" pattern as RecordingsView/HomeView.
    @State private var entries: [MissedCallEntry] = MissedCallHistory.shared.entries

    private let didChangePublisher = NotificationCenter.default
        .publisher(for: MissedCallHistory.didChangeNotification)
        .receive(on: DispatchQueue.main)

    var body: some View {
        Group {
            if entries.isEmpty {
                ContentUnavailableView(
                    "Пропущених дзвінків ще немає",
                    systemImage: "phone.down.fill",
                    description: Text("Тут з'являться звіти після першого «Не додзвонився».")
                )
            } else {
                List(entries) { entry in
                    MissedCallRow(entry: entry)
                }
            }
        }
        .navigationTitle("Пропущені дзвінки")
        .onReceive(didChangePublisher) { _ in
            entries = MissedCallHistory.shared.entries
        }
    }
}

private struct MissedCallRow: View {
    let entry: MissedCallEntry

    var body: some View {
        HStack(spacing: 12) {
            statusIcon
                .font(.title2)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(entry.callType)
                    .font(.headline)
                HStack(spacing: 6) {
                    if entry.hasManager {
                        Text(entry.manager)
                    }
                    Text(entry.missedAt.formatted(date: .abbreviated, time: .shortened))
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }

            Spacer()

            if !entry.screenshotUrls.isEmpty {
                Label("\(entry.screenshotUrls.count)", systemImage: "photo.on.rectangle")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .help("Кількість прикріплених скріншотів")
            }

            Text(entry.statusText)
                .font(.subheadline)
                // Explicit `Color` (not the bare `.secondary`/`.orange`
                // static members) — a ternary of two `ShapeStyle` static
                // members doesn't type-check as a single `ShapeStyle`
                // ("Type 'any ShapeStyle' cannot conform to 'ShapeStyle'"),
                // it needs a concrete common type to resolve to.
                .foregroundStyle(entry.kommoDelivered ? Color.secondary : Color.orange)

            if let crmUrl = URL(string: entry.crmUrl) {
                Link(destination: crmUrl) {
                    Image(systemName: "arrow.up.right.square")
                }
                .help("Відкрити лід у Kommo")
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusIcon: some View {
        if entry.kommoDelivered {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Image(systemName: "clock.fill")
                .foregroundStyle(.orange)
        }
    }
}
