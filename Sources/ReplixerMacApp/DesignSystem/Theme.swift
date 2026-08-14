import SwiftUI

/// Shared visual language for every ReplixerMac screen — spacing, corner
/// radii and semantic status colors pulled out of the ad-hoc literals each
/// screen used to invent on its own (e.g. the old `HomeView.statusCard`'s
/// `.background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius:
/// 12))`), so every card/badge/icon in the app now reads as one consistent
/// design instead of five slightly-different ones.
///
/// Built entirely from stable SwiftUI APIs already available at this
/// package's macOS 14.2 deployment floor (`Package.swift`) — `Material`,
/// hierarchical `ShapeStyle`s, `Color.gradient` (macOS 13+) — nothing here
/// reaches for a newer OS than the rest of the app already requires.
enum Theme {
    enum Spacing {
        static let screen: CGFloat = 20
        static let card: CGFloat = 18
        static let item: CGFloat = 12
        static let tight: CGFloat = 6
    }

    enum Radius {
        static let card: CGFloat = 14
        static let control: CGFloat = 9
        static let icon: CGFloat = 8
    }

    /// Status meanings shared across `RecordingEntry.status` and
    /// `MissedCallEntry` — named by what they mean, not by hue, so a future
    /// palette tweak only touches this one place instead of every call site
    /// that used to hardcode `.red`/`.green`/`.orange` directly.
    enum Status {
        static let recording = Color.red
        static let saved = Color.green
        static let warning = Color.orange
        static let draft = Color.yellow
        static let idle = Color.secondary
        static let info = Color.accentColor
    }
}

extension View {
    /// The app's one card surface — rounded, material-backed, softly
    /// bordered and shadowed. Used for every "panel" on Home/Recordings/
    /// MissedCalls instead of each screen hand-rolling its own background.
    func cardSurface(padding: CGFloat = Theme.Spacing.card) -> some View {
        modifier(CardSurfaceModifier(padding: padding))
    }

    /// A single list-style row inside a card — consistent hover highlight
    /// and vertical rhythm for every row-based list in the app (recent
    /// activity, recordings, missed calls).
    func cardRow() -> some View {
        modifier(CardRowModifier())
    }

    /// Small bold uppercase caption heading an in-card section (e.g. Home's
    /// "ОСТАННІ ЗАПИСИ") — pulled out so every such label matches exactly.
    func sectionCaptionStyle() -> some View {
        font(.system(.caption, design: .rounded).weight(.bold))
            .foregroundStyle(.secondary)
            .tracking(0.6)
    }
}

private struct CardSurfaceModifier: ViewModifier {
    let padding: CGFloat

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(.background)
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .fill(.quaternary.opacity(0.35))
                RoundedRectangle(cornerRadius: Theme.Radius.card, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.05), radius: 8, x: 0, y: 2)
    }
}

private struct CardRowModifier: ViewModifier {
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(isHovering ? Color.primary.opacity(0.05) : Color.clear)
            )
            .onHover { isHovering = $0 }
    }
}

/// A small icon inside a tinted rounded shape — the recurring "colorful
/// glyph badge" used throughout the app (sidebar rows, status cards, dialog
/// headers) instead of a bare `Image(systemName:)`.
struct IconBadge: View {
    let systemImage: String
    let tint: Color
    var size: CGFloat = 40
    var shape: BadgeShape = .circle

    enum BadgeShape {
        case circle
        case roundedSquare
    }

    var body: some View {
        ZStack {
            backgroundShape
                .fill(tint.opacity(0.16))
            Image(systemName: systemImage)
                .font(.system(size: size * 0.44, weight: .semibold))
                .foregroundStyle(tint)
                .symbolRenderingMode(.hierarchical)
        }
        .frame(width: size, height: size)
    }

    private var backgroundShape: AnyShape {
        switch shape {
        case .circle:
            return AnyShape(Circle())
        case .roundedSquare:
            return AnyShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
        }
    }
}

/// A small pill-shaped status label — replaces bare colored `Text`/`Label`
/// status readouts (e.g. `MissedCallsView`'s `entry.statusText`) with a
/// consistent, more legible tinted-capsule treatment.
struct StatusBadge: View {
    let text: String
    let tint: Color
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.15), in: Capsule())
    }
}

/// A gently pulsing filled circle — the "recording" heartbeat dot used on
/// Home's status card and the sidebar's Home row. Pure `.repeatForever`
/// animation, no timers, so it costs nothing when off-screen (SwiftUI
/// suspends animations on hidden views).
struct PulsingDot: View {
    var color: Color = Theme.Status.recording
    var size: CGFloat = 8

    @State private var isPulsing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.35))
                .frame(width: size * 2.2, height: size * 2.2)
                .scaleEffect(isPulsing ? 1 : 0.5)
                .opacity(isPulsing ? 0 : 0.8)
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                isPulsing = true
            }
        }
    }
}
