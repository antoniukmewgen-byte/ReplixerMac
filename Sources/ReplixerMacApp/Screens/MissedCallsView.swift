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
                // Same plain-list + hidden-chrome treatment as
                // RecordingsView, so each MissedCallRow's `.cardSurface()`
                // reads as its own floating card.
                List(entries) { entry in
                    MissedCallRow(entry: entry)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: Theme.Spacing.screen, bottom: 5, trailing: Theme.Spacing.screen))
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
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
        HStack(spacing: 14) {
            IconBadge(
                systemImage: entry.kommoDelivered ? "checkmark.circle.fill" : "clock.fill",
                tint: entry.kommoDelivered ? Theme.Status.saved : Theme.Status.warning,
                size: 38
            )

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

            // StatusBadge, not the old bare-Text ternary-foregroundStyle
            // workaround — same `entry.kommoDelivered ? … : …` condition,
            // just resolved to a `Color` up front (avoiding the "ternary of
            // two ShapeStyle statics doesn't type-check" issue the old
            // comment here explained) and rendered as a tinted pill.
            StatusBadge(
                text: entry.statusText,
                tint: entry.kommoDelivered ? Theme.Status.idle : Theme.Status.warning
            )

            if let crmUrl = URL(string: entry.crmUrl) {
                Link(destination: crmUrl) {
                    Image(systemName: "arrow.up.right.square")
                }
                .help("Відкрити лід у Kommo")
            }
        }
        .cardSurface(padding: 14)
    }
}
