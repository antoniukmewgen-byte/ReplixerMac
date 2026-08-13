import SwiftUI
import ReplixerMacCore

/// Windows parity source: `ViewModels/Dialogs/CallReportViewModel.cs` +
/// its XAML — the blocking "звіт по дзвінку" form shown after a call ends,
/// before Drive/Telegram upload starts (see `CallRecordingCoordinator
/// .finishRecording`, which awaits `CallReportRequestStore.shared
/// .requestReport` and only proceeds to upload once this view calls
/// `submit(_:)`).
///
/// Plain-@State-in-View, no formal ViewModel class — same pattern as every
/// other mac screen (`SetupWizardView`, `SettingsView`, `ProfileView`).
/// Field visibility is driven live by `PositionPolicy` + the couple of
/// local view-only rules Windows kept on the ViewModel itself (`isNedozvon`
/// /`hidesRatingOutcome`, custom-call-type/custom-outcome/invoice/payment-
/// probability reveals) — ported verbatim rather than simplified, per the
/// explicit "full parity, Менеджер/Діагност/Кваліфікатор" instruction.
///
/// No cancel button and `.interactiveDismissDisabled()` at the call site
/// (`ContentView`) — matches Windows, which has no "dismiss without
/// reporting" affordance here either. The only way this sheet closes
/// without the user pressing "Відправити" is `CallReportRequestStore
/// .interrupt()` (Phase 11.3) firing externally when a new call arrives —
/// same as Windows' `ShowDialog` forcibly dismissing an open report, not a
/// user-facing cancel.
struct CallReportView: View {
    let platform: String
    let duration: TimeInterval

    // Position is fixed for the lifetime of this sheet (read once from
    // AppSettings at creation, like `managerName`/`_position` being
    // constructor-only on the Windows ViewModel) — the picker in
    // SettingsView is what actually changes it, not this form.
    private let position: String = AppSettings.shared.position
    private let managerName: String = AppSettings.shared.managerName

    // Explicit init, even though it only assigns the two params Swift would
    // otherwise memberwise-generate for free: `position`/`managerName`
    // being `private` would make an auto-generated memberwise init
    // `private` too (Swift caps a struct's implicit init at its most
    // restrictive stored-property access level) — which would confine
    // construction to this file and break ContentView's `.sheet(item:)`
    // call site. Their own `= AppSettings.shared....` default-value
    // expressions still apply automatically since this init never touches
    // them.
    //
    // Phase 11.3: `existing` prefills every @State field from a previously
    // interrupted draft (Windows parity: `CallReportViewModel`'s
    // `existing:` constructor param) — nil for a normal post-call report,
    // where every field just keeps its own `= ...` default below. Position/
    // manager are deliberately NOT part of the prefill (still read fresh
    // from AppSettings above) — same as Windows, which re-reads `_position`/
    // `_managerName` on every open rather than persisting them into the
    // resumed draft, since whoever resumes it might not be whoever started
    // the call.
    init(platform: String, duration: TimeInterval, existing: CallReportData? = nil) {
        self.platform = platform
        self.duration = duration
        if let existing {
            _selectedCallType = State(initialValue: existing.callType.isEmpty ? nil : existing.callType)
            _customCallType = State(initialValue: existing.customCallType ?? "")
            _selectedLeadSource = State(initialValue: existing.leadSource.isEmpty ? nil : existing.leadSource)
            _selectedRating = State(initialValue: existing.rating.isEmpty ? nil : existing.rating)
            _selectedOutcome = State(initialValue: existing.outcome.isEmpty ? nil : existing.outcome)
            _customOutcome = State(initialValue: existing.customOutcome ?? "")
            _isInvoicePaid = State(initialValue: existing.isInvoicePaid ?? false)
            _selectedPaymentProbability = State(initialValue: existing.paymentProbability.isEmpty ? nil : existing.paymentProbability)
            _crmUrl = State(initialValue: existing.crmUrl)
            _note = State(initialValue: existing.note)
        }
    }

    @State private var selectedCallType: String?
    @State private var customCallType: String = ""
    @State private var selectedLeadSource: String?
    @State private var selectedRating: String?
    @State private var selectedOutcome: String?
    @State private var customOutcome: String = ""
    @State private var isInvoicePaid = false
    @State private var selectedPaymentProbability: String?
    @State private var crmUrl: String = ""
    @State private var note: String = ""

    private static let noteMaxLength = 500

    // MARK: - Visibility (verbatim port of CallReportViewModel.cs)

    private var isNedozvon: Bool {
        selectedCallType == "Недодзвон (ще не було спілкування)" || selectedCallType == "Недодзвон (вже було спілкування)"
    }
    private var hidesRatingOutcome: Bool { isNedozvon || selectedCallType == "Інший" }

    private var isCallTypeVisible: Bool { PositionPolicy.isCallTypeVisible(position) }
    private var isCustomCallTypeVisible: Bool { isCallTypeVisible && selectedCallType == "Інший" }
    private var isLeadSourceVisible: Bool { PositionPolicy.isLeadSourceVisible(position) }
    private var isRatingVisible: Bool { PositionPolicy.isRatingVisible(position) && !hidesRatingOutcome }
    private var isOutcomeVisible: Bool { PositionPolicy.isOutcomeVisible(position) && !hidesRatingOutcome }
    private var isCustomOutcomeVisible: Bool { selectedOutcome == "Інший" }
    private var isInvoiceCheckboxVisible: Bool { selectedOutcome == "Виставив рахунок" }
    private var isPaymentProbabilityVisible: Bool { selectedOutcome == "Виставив рахунок" }

    private var isCrmUrlInvalid: Bool {
        !crmUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !UrlValidator.isValidHttpUrl(crmUrl)
    }

    // MARK: - Submit gating (verbatim port of CanSubmit())

    private var canSubmit: Bool {
        switch position {
        case "Діагност":
            return UrlValidator.isValidHttpUrl(crmUrl) && !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case "Кваліфікатор":
            return selectedLeadSource != nil
                && UrlValidator.isValidHttpUrl(crmUrl)
                && !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        default:
            return selectedCallType != nil
                && selectedLeadSource != nil
                && (!isRatingVisible || selectedRating != nil)
                && (!isOutcomeVisible || selectedOutcome != nil)
                && (!isPaymentProbabilityVisible || selectedPaymentProbability != nil)
                && UrlValidator.isValidHttpUrl(crmUrl)
                && !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Менеджер", value: managerName.isEmpty ? "—" : managerName)
                LabeledContent("Роль", value: position)
                LabeledContent("Дзвінок", value: platform)
            }

            if isCallTypeVisible {
                Section("Тип дзвінка") {
                    Picker("Тип дзвінка", selection: $selectedCallType) {
                        Text("Не обрано").tag(String?.none)
                        ForEach(CallReportData.callTypes, id: \.self) { type in
                            Text(type).tag(String?.some(type))
                        }
                    }
                    .labelsHidden()

                    if isCustomCallTypeVisible {
                        TextField("Уточніть тип дзвінка", text: $customCallType)
                    }
                }
            }

            if isLeadSourceVisible {
                Section("Джерело ліда") {
                    Picker("Джерело ліда", selection: $selectedLeadSource) {
                        Text("Не обрано").tag(String?.none)
                        ForEach(CallReportData.leadSources, id: \.self) { source in
                            Text(source).tag(String?.some(source))
                        }
                    }
                    .labelsHidden()
                }
            }

            if isRatingVisible {
                Section("Оцінка розмови") {
                    Picker("Оцінка розмови", selection: $selectedRating) {
                        Text("Не обрано").tag(String?.none)
                        ForEach(CallReportData.ratings, id: \.self) { rating in
                            Text("\(rating)/10").tag(String?.some(rating))
                        }
                    }
                    .labelsHidden()
                }
            }

            if isOutcomeVisible {
                Section("До чого дійшли") {
                    Picker("До чого дійшли", selection: $selectedOutcome) {
                        Text("Не обрано").tag(String?.none)
                        ForEach(CallReportData.outcomes, id: \.self) { outcome in
                            Text(outcome).tag(String?.some(outcome))
                        }
                    }
                    .labelsHidden()

                    if isCustomOutcomeVisible {
                        TextField("Уточніть, до чого дійшли", text: $customOutcome)
                    }

                    if isInvoiceCheckboxVisible {
                        Toggle("Рахунок оплачено", isOn: $isInvoicePaid)
                    }
                }
            }

            if isPaymentProbabilityVisible {
                Section("Вірогідність оплати") {
                    Picker("Вірогідність оплати", selection: $selectedPaymentProbability) {
                        Text("Не обрано").tag(String?.none)
                        ForEach(CallReportData.ratings, id: \.self) { value in
                            Text("\(value)/10").tag(String?.some(value))
                        }
                    }
                    .labelsHidden()
                }
            }

            Section("CRM") {
                TextField("Посилання на лід у Kommo", text: $crmUrl)
                if isCrmUrlInvalid {
                    Label("Очікується посилання виду https://<акаунт>.kommo.com/leads/detail/<id>", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }

            Section("Примітка") {
                TextEditor(text: $note)
                    .frame(minHeight: 80)
                    .onChange(of: note) { _, newValue in
                        if newValue.count > Self.noteMaxLength {
                            note = String(newValue.prefix(Self.noteMaxLength))
                        }
                    }
                Text("\(note.count)/\(Self.noteMaxLength)")
                    .font(.caption)
                    .foregroundStyle(note.count >= Self.noteMaxLength - 50 ? .orange : .secondary)
            }

            Section {
                Button("Відправити") {
                    submit()
                }
                .disabled(!canSubmit)
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Звіт по дзвінку")
        // Phase 11.3: keeps CallReportRequestStore's liveDraft continuously
        // up to date so `interrupt()` — called from AppDelegate, outside
        // SwiftUI, with no direct read access to this view's @State — always
        // has something recent to hand back if a new call bumps this form
        // before the user finishes it. Windows parity: `CaptureDraft()`
        // reads a persistent ViewModel's fields on demand; mac has no such
        // object here, so it pushes instead of being pulled from.
        .onChange(of: selectedCallType) { _, _ in pushLiveDraft() }
        .onChange(of: customCallType) { _, _ in pushLiveDraft() }
        .onChange(of: selectedLeadSource) { _, _ in pushLiveDraft() }
        .onChange(of: selectedRating) { _, _ in pushLiveDraft() }
        .onChange(of: selectedOutcome) { _, _ in pushLiveDraft() }
        .onChange(of: customOutcome) { _, _ in pushLiveDraft() }
        .onChange(of: isInvoicePaid) { _, _ in pushLiveDraft() }
        .onChange(of: selectedPaymentProbability) { _, _ in pushLiveDraft() }
        .onChange(of: crmUrl) { _, _ in pushLiveDraft() }
        .onChange(of: note) { _, _ in pushLiveDraft() }
        // No frame here on purpose — ContentView's .sheet(item:) call site
        // now owns sizing (width fixed at 500, matching Windows'
        // Views/Dialogs/CallReportView.xaml Width="500" card; height pinned
        // to the live main-window height minus margin, see
        // ContentView.reportSheetHeight's doc comment). Setting a
        // conflicting frame here would just make this view's intrinsic
        // size win over the sheet's actual presented size instead of
        // filling it. `Form` already behaves like a List/ScrollView
        // internally, so whatever height it's given, content that doesn't
        // fit scrolls in place rather than being clipped.
    }

    // Phase 11.3: pulled out of `submit()` so the same construction logic
    // also backs the live-draft push (`pushLiveDraft()`) — visibility-gated
    // the same way in both cases, so an interrupted draft prefills exactly
    // what a full submit at that point would have sent.
    private func buildReportData() -> CallReportData {
        CallReportData(
            manager: managerName,
            position: position,
            callType: isCallTypeVisible ? (selectedCallType ?? "") : "",
            customCallType: isCustomCallTypeVisible ? customCallType : nil,
            leadSource: isLeadSourceVisible ? (selectedLeadSource ?? "") : "",
            crmUrl: crmUrl,
            rating: isRatingVisible ? (selectedRating ?? "") : "",
            outcome: isOutcomeVisible ? (selectedOutcome ?? "") : "",
            customOutcome: isCustomOutcomeVisible ? customOutcome : nil,
            isInvoicePaid: isInvoiceCheckboxVisible ? isInvoicePaid : nil,
            paymentProbability: isPaymentProbabilityVisible ? (selectedPaymentProbability ?? "") : "",
            note: note
        )
    }

    private func submit() {
        CallReportRequestStore.shared.submit(buildReportData())
    }

    private func pushLiveDraft() {
        CallReportRequestStore.shared.updateLiveDraft(buildReportData())
    }
}
