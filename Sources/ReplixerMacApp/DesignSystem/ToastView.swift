import SwiftUI
import ReplixerMacCore

/// Windows parity: the bottom-right toast stack `ItemsControl` in
/// `MainWindow.xaml`. Mirrors `ToastStore.shared.items` into local `@State`
/// via the same `.onReceive(NotificationCenter...)` pattern `ContentView`
/// already uses for its three request stores, then lets `ForEach` + a plain
/// `.transition` supply the enter/exit animation SwiftUI already knows how
/// to do automatically — no `IsLeaving`/`AnimationCompleted` handshake
/// needed here (see `ToastStore`'s own doc comment for why).
struct ToastStackView: View {
    @State private var toasts: [ToastStore.Toast] = ToastStore.shared.items

    private let didChangePublisher = NotificationCenter.default
        .publisher(for: ToastStore.didChangeNotification)
        .receive(on: DispatchQueue.main)

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ForEach(toasts) { toast in
                ToastCardView(toast: toast)
                    .transition(
                        .asymmetric(
                            insertion: .move(edge: .trailing).combined(with: .opacity),
                            removal: .opacity
                        )
                    )
            }
        }
        .padding(16)
        // Windows parity: `IsHitTestVisible=False` — the stack floats over
        // the window's content without intercepting clicks meant for
        // whatever's underneath it.
        .allowsHitTesting(false)
        .onReceive(didChangePublisher) { _ in
            withAnimation(.easeOut(duration: 0.25)) {
                toasts = ToastStore.shared.items
            }
        }
    }
}

/// A single toast card — rounded rect, left accent border colored per
/// `kind` (Windows: `OtherBrushColor1`/`OtherBrushColor4` via `DataTrigger`
/// on `IsError`; here `Theme.Status.saved` for success and plain `.red` for
/// error, since `Theme.Status.recording` is semantically reserved for the
/// recording indicator elsewhere in the app), plus a ✓/✕ SF Symbol glyph.
private struct ToastCardView: View {
    let toast: ToastStore.Toast

    private var tint: Color {
        toast.kind == .success ? Theme.Status.saved : .red
    }

    private var systemImage: String {
        toast.kind == .success ? "checkmark.circle.fill" : "xmark.circle.fill"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(tint)
            Text(toast.message)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(width: 290, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.background)
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.regularMaterial)
        }
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(tint)
                .frame(width: 3)
                .padding(.vertical, 6)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .shadow(color: .black.opacity(0.15), radius: 10, x: 0, y: 4)
    }
}
