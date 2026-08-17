import SwiftUI

/// Phase 13.1 — call-script checklist shown while a call is being recorded.
/// Windows parity source: `Views/CallCheatSheetWindow.xaml` — same 7-step
/// Ukrainian sales-call script, same "checking an item just dims it, no
/// persistence" behavior (Windows never persists checkbox state either —
/// a fresh call always starts with everything unchecked, and so does this
/// view, since it's a fresh `NSHostingView` every time
/// `CheatSheetWindowController` shows the panel).
///
/// Content only — window chrome/positioning/show-hide lifecycle lives in
/// `CheatSheetWindowController` (AppKit, since this needs to float over
/// every window on screen including non-SwiftUI ones, which `.sheet`/
/// SwiftUI `Window` scenes can't do).
struct CheatSheetView: View {
    private static let steps = [
        "Привітання, тест на дебіла та встановлення рамок",
        "Первинний анамнез та підводимо лінію",
        "Вторинний анамнез, розкриваємо досвід клієнта через техніку \"ближче-далі\"",
        "Знайшли зачіпку, інтегруємо приклад успішного кейсу та аппрува",
        "Прийом \"чашка чаю\" + \"ваш кейс унікальний, антиприклад щойно був порожній кейс\"",
        "Ставимо дедлайн, вибираємо день і час",
        "Закриття у дзвінку, отримуємо ім'я, прізвище, пошту. І приймаємо оплату на реквізити",
    ]

    // Local, unpersisted — same as Windows (a fresh recording always starts
    // with every step unchecked). Thrown away with the panel itself when
    // `CheatSheetWindowController.hide()` tears it down.
    @State private var checked: Set<Int> = []

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
                .opacity(0.5)
            VStack(spacing: 2) {
                ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, text in
                    stepRow(index: index, text: text)
                }
            }
            .padding(8)
        }
        .frame(width: 300)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 6)
        // Breathing room for the shadow above to fall off into instead of
        // clipping at the panel's edge — same reasoning Windows'
        // CallCheatSheetWindow doc comment gives for its own Margin.
        .padding(24)
    }

    private var header: some View {
        HStack(spacing: 10) {
            // Windows' 2x3 dot-grid "drag handle" hint — purely decorative
            // here since the whole panel is already draggable by background
            // (CheatSheetWindowController sets isMovableByWindowBackground),
            // kept for the same "this card can be moved" visual cue.
            VStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { _ in
                    HStack(spacing: 2) {
                        Circle().frame(width: 2.5, height: 2.5)
                        Circle().frame(width: 2.5, height: 2.5)
                    }
                }
            }
            .foregroundStyle(.tertiary)

            Text("ШПАРГАЛКА")
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func stepRow(index: Int, text: String) -> some View {
        let isChecked = checked.contains(index)
        return Button {
            withAnimation(.easeOut(duration: 0.15)) {
                if isChecked {
                    checked.remove(index)
                } else {
                    checked.insert(index)
                }
            }
        } label: {
            HStack(alignment: .top, spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isChecked ? Theme.Status.info.opacity(0.15) : Color.clear)
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(isChecked ? Theme.Status.info : Color.secondary.opacity(0.4), lineWidth: 1.5)
                    if isChecked {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.Status.info)
                    } else {
                        Text("\(index + 1)")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 20, height: 20)
                .padding(.top, 1)

                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .opacity(isChecked ? 0.35 : 1)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    CheatSheetView()
        .padding(40)
}
