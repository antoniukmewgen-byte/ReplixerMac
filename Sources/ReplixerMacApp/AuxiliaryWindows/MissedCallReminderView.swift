import SwiftUI

/// Windows parity: `Views/MissedCallReminderWindow.xaml`'s content — a
/// static, undismissable instructional card with zero bindings/state (no
/// ViewModel there either). Colors match Windows' `OtherBrushColor4`
/// (#2D1A1A, card background) and `OtherBrushSubColor4` (#C64444, border +
/// icon badge) from `Resources/Colors.xaml` — this pairing doesn't exist in
/// `Theme.swift` (it's a one-off "urgent reminder" red-brown, distinct from
/// `Theme.Status.recording`'s pure red), so it's hardcoded here rather than
/// added to the shared design system for a single call site.
struct MissedCallReminderView: View {
    private static let cardBackground = Color(red: 0.176, green: 0.102, blue: 0.102)
    private static let accent = Color(red: 0.776, green: 0.267, blue: 0.267)

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                Circle().fill(Self.accent)
                Text("!")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)

            Text("Якщо клієнт не відповів — натисніть кнопку «Не додзвонився» в застосунку Replixer")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(width: 320, alignment: .leading)
        .background(Self.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Self.accent, lineWidth: 1.5)
        }
    }
}
