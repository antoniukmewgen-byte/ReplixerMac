import SwiftUI

/// Phase 13.2 — floating world-clock widget content. Windows parity source:
/// `Views/WorldClockWindow.xaml(.cs)` — Kyiv (home zone, 24h) + 6 US zones
/// (12h AM/PM), live per-second update, a day/night-phase icon + tint per
/// row, and for non-Kyiv zones a relative-offset label ("+7 год від
/// Києва") plus "· завтра"/"· вчора" when the local calendar date differs
/// from Kyiv's.
///
/// `TimelineView(.periodic(...))` stands in for Windows' `DispatcherTimer` —
/// SwiftUI's native per-second-redraw primitive, so there's no manual
/// Timer/@State bookkeeping to tear down when the panel closes.
///
/// Content only — window chrome/positioning/show-hide-toggle lifecycle
/// lives in `WorldClockWindowController` (AppKit, same "needs to float
/// over every window on screen" reasoning as `CheatSheetView`).
struct WorldClockView: View {
    private struct Zone {
        let identifier: String
        let label: String
        let isHome: Bool
    }

    private static let kyivIdentifier = "Europe/Kyiv"

    private static let zones: [Zone] = [
        Zone(identifier: kyivIdentifier, label: "Київ", isHome: true),
        Zone(identifier: "America/New_York", label: "Нью-Йорк · Східний", isHome: false),
        Zone(identifier: "America/Chicago", label: "Чикаго · Центральний", isHome: false),
        Zone(identifier: "America/Denver", label: "Денвер · Гірський", isHome: false),
        Zone(identifier: "America/Los_Angeles", label: "Лос-Анджелес · Тихоокеанський", isHome: false),
        Zone(identifier: "America/Anchorage", label: "Анкоридж · Аляска", isHome: false),
        Zone(identifier: "Pacific/Honolulu", label: "Гонолулу · Гаваї", isHome: false),
    ]

    /// Called by `WorldClockWindowController` when the user clicks the
    /// close (✕) button in the header — this view has no window/panel
    /// reference of its own to call `NSWindow.close()` directly, same
    /// "controller owns the window, view just asks to be dismissed"
    /// split `CallReportRequestStore`-driven sheets use.
    var onClose: () -> Void

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 0) {
                header
                Divider()
                    .opacity(0.5)
                VStack(spacing: 3) {
                    ForEach(Self.zones, id: \.identifier) { zone in
                        row(for: zone, now: context.date)
                    }
                }
                .padding(10)
            }
        }
        .frame(width: 280)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.1), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .shadow(color: .black.opacity(0.35), radius: 24, x: 0, y: 6)
        .padding(24)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("СВІТОВИЙ ГОДИННИК")
                .font(.system(.caption, design: .rounded).weight(.semibold))
                .foregroundStyle(.secondary)
                .tracking(0.6)

            Spacer()

            // Windows' equivalent (`CloseButton_MouseLeftButtonDown`) is the
            // only way to dismiss this window — unlike the cheat sheet,
            // which is entirely lifecycle-driven, the world clock is a
            // manually-opened utility the user closes when done with it.
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private func row(for zone: Zone, now: Date) -> some View {
        if let timeZone = TimeZone(identifier: zone.identifier) {
            let hour = Self.hour(in: timeZone, at: now)
            let phase = Self.phase(forHour: hour)

            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(phase.tint.opacity(0.16))
                    Image(systemName: phase.symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(phase.tint)
                }
                .frame(width: 26, height: 26)

                VStack(alignment: .leading, spacing: 1) {
                    Text(zone.label)
                        .font(.system(size: 12, weight: .medium))
                    Text(Self.subtitle(for: zone, timeZone: timeZone, at: now))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(Self.timeText(for: zone, timeZone: timeZone, at: now))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(phase.tint)
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private static func hour(in timeZone: TimeZone, at date: Date) -> Int {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.component(.hour, from: date)
    }

    private static func timeText(for zone: Zone, timeZone: TimeZone, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = timeZone
        // en_US_POSIX, not the system locale — guarantees English "AM"/"PM"
        // for the US zones regardless of the Mac's own locale, same as
        // Windows' `CultureInfo.InvariantCulture` reasoning.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = zone.isHome ? "HH:mm" : "h:mm a"
        return formatter.string(from: date)
    }

    /// `nil`-safe fallback to `.current` only matters if `Europe/Kyiv`
    /// somehow isn't in the system's tzdata — shouldn't happen on any
    /// macOS version this app targets, but a force-unwrap here would crash
    /// the whole panel over a single missing identifier.
    private static func subtitle(for zone: Zone, timeZone: TimeZone, at date: Date) -> String {
        guard !zone.isHome else { return "Домашній пояс" }

        let kyivZone = TimeZone(identifier: kyivIdentifier) ?? .current
        let diffHours = Int((Double(timeZone.secondsFromGMT(for: date) - kyivZone.secondsFromGMT(for: date)) / 3600).rounded())
        let diffLabel = diffHours == 0 ? "той самий час" : "\(diffHours > 0 ? "+" : "")\(diffHours) год від Києва"

        var zoneCalendar = Calendar(identifier: .gregorian)
        zoneCalendar.timeZone = timeZone
        var kyivCalendar = Calendar(identifier: .gregorian)
        kyivCalendar.timeZone = kyivZone

        let zoneDay = zoneCalendar.startOfDay(for: date)
        let kyivDay = kyivCalendar.startOfDay(for: date)
        let dayDiff = zoneCalendar.dateComponents([.day], from: kyivDay, to: zoneDay).day ?? 0
        let dayLabel = dayDiff > 0 ? " · завтра" : (dayDiff < 0 ? " · вчора" : "")

        return diffLabel + dayLabel
    }

    private struct Phase {
        let symbol: String
        let tint: Color
    }

    /// Same 4-bucket hour ranges as Windows' `GetPhaseVisual` (5–8 dawn,
    /// 8–18 day, 18–21 dusk, else night) — SF Symbols instead of Windows'
    /// hand-built vector geometry (it avoided a dependency on an emoji
    /// font that might be missing from its custom `InterFont`; SF Symbols
    /// already ship with every macOS system font stack, so there's no
    /// equivalent dependency to avoid here).
    private static func phase(forHour hour: Int) -> Phase {
        switch hour {
        case 5..<8: return Phase(symbol: "sunrise.fill", tint: .purple)
        case 8..<18: return Phase(symbol: "sun.max.fill", tint: .orange)
        case 18..<21: return Phase(symbol: "sunset.fill", tint: .pink)
        default: return Phase(symbol: "moon.stars.fill", tint: .indigo)
        }
    }
}

#Preview {
    WorldClockView(onClose: {})
        .padding(40)
}
