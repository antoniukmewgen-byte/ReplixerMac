import Foundation

/// Windows parity source: `ViewModels/Dialogs/CallReportViewModel.cs`'s
/// `CallReportData` record + its `FormatCaption()` method, plus the static
/// option lists that used to live on `CallReportViewModel` itself.
///
/// Pure data + pure formatting — no view-model state. `CallReportView`
/// (ReplixerMacApp, Phase 10) owns @State directly and builds one of these
/// on submit, same pattern as every other mac screen (see
/// `SetupWizardView`'s doc comment on why this codebase skips formal
/// ViewModel classes).
///
/// `appName`/`duration` deliberately aren't stored properties here (unlike
/// Windows, which mutates them onto the record post-hoc via `with { ... }`
/// once `StopRecordingAsync` knows the platform/duration) — the report form
/// itself never collects either value, so `formatCaption` takes them as
/// parameters instead, supplied by whoever (CallRecordingCoordinator)
/// actually knows them.
public struct CallReportData: Codable, Equatable, Sendable {
    public var manager: String
    public var position: String
    public var callType: String
    public var customCallType: String?
    public var leadSource: String
    public var crmUrl: String
    public var rating: String
    public var outcome: String
    public var customOutcome: String?
    public var isInvoicePaid: Bool?
    public var paymentProbability: String
    public var note: String

    public init(
        manager: String,
        position: String,
        callType: String,
        customCallType: String? = nil,
        leadSource: String,
        crmUrl: String,
        rating: String,
        outcome: String,
        customOutcome: String? = nil,
        isInvoicePaid: Bool? = nil,
        paymentProbability: String,
        note: String
    ) {
        self.manager = manager
        self.position = position
        self.callType = callType
        self.customCallType = customCallType
        self.leadSource = leadSource
        self.crmUrl = crmUrl
        self.rating = rating
        self.outcome = outcome
        self.customOutcome = customOutcome
        self.isInvoicePaid = isInvoicePaid
        self.paymentProbability = paymentProbability
        self.note = note
    }

    /// Windows parity source: `CallReportData.FormatCaption()` — verbatim
    /// line-for-line port (same emoji prefixes, same field order, same
    /// `#оплата` hashtag suffix), just with `appName`/`duration` as params
    /// instead of stored properties (see type doc comment above).
    public func formatCaption(appName: String, duration: TimeInterval) -> String {
        let resolvedCallType: String = {
            if callType == "Інший", let customCallType, !customCallType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return customCallType
            }
            return callType
        }()

        var resolvedOutcome: String = {
            if outcome == "Інший", let customOutcome, !customOutcome.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return customOutcome
            }
            return outcome
        }()
        if outcome == "Виставив рахунок", let isInvoicePaid {
            resolvedOutcome = "Виставив рахунок (\(isInvoicePaid ? "Оплатив ✅" : "Не оплатив ❌"))"
        }

        let durationString: String? = {
            guard duration > 0 else { return nil }
            let totalSeconds = Int(duration.rounded())
            let hours = totalSeconds / 3600
            let minutes = (totalSeconds % 3600) / 60
            let seconds = totalSeconds % 60
            if hours > 0 {
                return String(format: "%d:%02d:%02d", hours, minutes, seconds)
            }
            return String(format: "%02d:%02d", minutes, seconds)
        }()

        var lines: [String] = []
        lines.append(appName.isEmpty ? "📋 Звіт по дзвінку" : "📋 Звіт по дзвінку | \(appName)")
        lines.append("")
        lines.append("👤 \(position): \(manager)")
        if !resolvedCallType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("📞 Тип дзвінка: \(resolvedCallType)")
        }
        if let durationString {
            lines.append("⏱ Тривалість: \(durationString)")
        }
        if !leadSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("📣 Джерело ліда: \(leadSource)")
        }
        if !rating.isEmpty {
            lines.append("⭐ Оцінка розмови: \(rating)/10")
        }
        if !resolvedOutcome.isEmpty {
            lines.append("✅ До чого дійшли: \(resolvedOutcome)")
        }
        if !paymentProbability.isEmpty {
            lines.append("💰 Вірогідність оплати: \(paymentProbability)/10")
        }
        if !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("📝 Примітка: \(note)")
        }
        if !crmUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("🔗 CRM: \(crmUrl)")
        }

        var result = lines.joined(separator: "\n")
        if outcome == "Виставив рахунок" && isInvoicePaid == true {
            result += "\n#оплата"
        }
        return result
    }

    // MARK: - Windows-parity static option lists (CallReportViewModel.cs)

    public static let callTypes: [String] = [
        "Перший дзвінок", "Передзвін (перший дзвінок)", "Перший контакт", "Повторний контакт",
        "Дзвінок після (подумаю/пораджуся)", "Дзвінок КК", "Недодзвон (ще не було спілкування)",
        "Недодзвон (вже було спілкування)", "Інший",
    ]

    public static let leadSources: [String] = [
        "Лідформа Фейсбук", "Рекомендація", "Лідформа Тікток", "Реактивація", "Вторинне опрацювання",
        "Листування в соцмережах", "Квіз", "FB + WA", "YouTube", "Кваліфікація Реакт",
        "Кваліфікація Гаряч", "WA",
    ]

    public static let ratings: [String] = (1...10).map(String.init)

    public static let outcomes: [String] = [
        "Оплатив у розмові", "Виставив рахунок", "Пішов думати", "Потрібно порадитися",
        "Не підходять умови", "Не цільовий", "Вже не актуально", "Неадекват",
        "Хоче оплатити в кінці роботи", "Вирішив виїжджати зі США", "Хоче зайнятися пізніше",
        "Домовились на передзвін", "Інший",
    ]

    public static let positions: [String] = ["Менеджер", "Діагност", "Кваліфікатор"]
}
