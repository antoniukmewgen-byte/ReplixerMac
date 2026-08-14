import SwiftUI
import ReplixerMacCore

/// Windows parity source: `ViewModels/Dialogs/MissedCallReportViewModel.cs`
/// + its XAML — the "Не додзвонився" form: call type, an editable "first
/// contact" time (only for "ще не було спілкування" types), a CRM link, and
/// per-messenger "quick action" buttons that drive
/// `MissedCallQuickActionService`'s deep-link → screenshot → upload
/// pipeline. Same plain-`@State`-in-View pattern as `CallReportView`/
/// `CallConfirmView` — no formal ViewModel class.
///
/// Unlike `CallReportView`, manual screenshot-URL text fields don't exist
/// here at all (ported straight from Windows, which already removed them —
/// see that ViewModel's comment on `CollectScreenshotUrls()`): the only way
/// `screenshotUrls`/`screenshotUrlsByMessenger` gets populated is a
/// successful quick action.
///
/// No cancel button, same reasoning as `CallReportView` — `ContentView`'s
/// `.interactiveDismissDisabled()` blocks Esc/swipe-away; there's no
/// Windows-side "close without reporting" affordance for this dialog either
/// (its WPF host is a modal `Window.ShowDialog()`).
struct MissedCallReportView: View {
    /// The moment "Не додзвонився" was clicked (`MissedCallReportRequestStore
    /// .PendingRequest.missedAt`) — default/fallback first-contact time, and
    /// the base the +/-1хв steppers adjust from when the text field itself
    /// doesn't parse.
    let missedAt: Date

    private let managerName: String = AppSettings.shared.managerName

    init(missedAt: Date) {
        self.missedAt = missedAt
        _firstContactTimeText = State(initialValue: Self.timeFormatter.string(from: missedAt))
    }

    @State private var selectedCallType: String?
    @State private var firstContactTimeText: String
    @State private var crmUrl: String = ""

    // Per-messenger quick-action state — mirrors the ViewModel's four
    // parallel Viber/Telegram/WhatsApp-keyed dictionaries
    // (Status/ActionFailed/ScreenshotUrl/busy-while-running) collapsed into
    // one `[messenger: ...]` dictionary each, since Swift doesn't need a
    // separate named property per messenger the way WPF data-binding does.
    @State private var messengerStatus: [String: String] = [:]
    @State private var messengerFailed: [String: Bool] = [:]
    @State private var messengerScreenshotUrl: [String: String] = [:]
    @State private var messengerBusy: [String: Bool] = [:]

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = MissedCallReportData.firstContactTimeFormat
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private var isNoCommunicationType: Bool { MissedCallReportData.isNoCommunicationType(selectedCallType) }
    private var requiredScreenshotCount: Int { isNoCommunicationType ? 2 : 1 }

    private var parsedFirstContactTime: Date? {
        Self.timeFormatter.date(from: firstContactTimeText.trimmingCharacters(in: .whitespacesAndNewlines))
    }
    private var isFirstContactTimeInvalid: Bool {
        isNoCommunicationType && parsedFirstContactTime == nil
    }
    private var isCrmUrlInvalid: Bool {
        !crmUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !UrlValidator.isValidHttpUrl(crmUrl)
    }

    // Windows parity: `CollectScreenshotUrls()` — compact list in
    // Messengers-declaration order (Viber, Telegram, WhatsApp), skipping
    // whichever messengers have no real uploaded URL yet.
    private func collectScreenshotUrls() -> [String] {
        MessengerDeepLinkProvider.supportedMessengers.compactMap { messengerScreenshotUrl[$0] }
    }

    private var hasEnoughScreenshots: Bool { collectScreenshotUrls().count >= requiredScreenshotCount }

    // Windows parity: `CanSubmit()`.
    private var canSubmit: Bool {
        selectedCallType != nil
            && UrlValidator.isValidHttpUrl(crmUrl)
            && !isFirstContactTimeInvalid
            && hasEnoughScreenshots
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Менеджер", value: managerName.isEmpty ? "—" : managerName)
            }

            Section("Тип дзвінка") {
                Picker("Тип дзвінка", selection: $selectedCallType) {
                    Text("Не обрано").tag(String?.none)
                    ForEach(MissedCallReportData.callTypes, id: \.self) { type in
                        Text(type).tag(String?.some(type))
                    }
                }
                .labelsHidden()
            }

            // Windows parity: `IsFirstContactTimeEditable` — only shown
            // (and thus only enforced via isFirstContactTimeInvalid) for
            // "ще не було спілкування" types.
            if isNoCommunicationType {
                Section("Час першого контакту") {
                    HStack(spacing: 8) {
                        TextField("дд.мм.рррр гг:хх", text: $firstContactTimeText)
                        Button {
                            adjustFirstContactTime(-1)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        Button {
                            adjustFirstContactTime(1)
                        } label: {
                            Image(systemName: "plus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                    if isFirstContactTimeInvalid {
                        Label("Очікується формат дд.мм.рррр гг:хх", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.caption)
                    }
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

            Section("Швидкі дії") {
                ForEach(MessengerDeepLinkProvider.supportedMessengers, id: \.self) { messenger in
                    messengerRow(messenger)
                }
                // Windows parity: `ShowScreenshotHint`/`ScreenshotHintText`.
                if selectedCallType != nil && !hasEnoughScreenshots {
                    Text(requiredScreenshotCount == 2
                        ? "Зробіть два скріншоти переписки, щоб відправити звіт"
                        : "Зробіть один скріншот переписки, щоб відправити звіт")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
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
        .navigationTitle("Пропущений дзвінок")
    }

    @ViewBuilder
    private func messengerRow(_ messenger: String) -> some View {
        HStack(spacing: 8) {
            Text(messenger)
                .frame(width: 84, alignment: .leading)

            // Windows parity: a successful quick action shows the real
            // Drive link in place of the status text (see
            // `SetMessengerStatus`'s doc comment on why the link and the
            // status string share one visual slot).
            if let url = messengerScreenshotUrl[messenger], let driveUrl = URL(string: url) {
                Link(destination: driveUrl) {
                    Text(url)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .font(.caption)
            } else if let status = messengerStatus[messenger] {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(messengerFailed[messenger] == true ? .red : .secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            } else {
                Spacer()
            }

            Spacer(minLength: 8)

            if messengerBusy[messenger] == true {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button(messengerScreenshotUrl[messenger] != nil ? "Ще раз" : "Відкрити") {
                    runQuickAction(messenger)
                }
                .controlSize(.small)
            }
        }
    }

    // Windows parity: `AdjustFirstContactTime` — steps off the currently
    // parseable text if there is one, otherwise off `missedAt` (the click
    // moment), same "don't let a manually-broken text field wedge the
    // steppers" fallback.
    private func adjustFirstContactTime(_ minutesDelta: Int) {
        let base = parsedFirstContactTime ?? missedAt
        let adjusted = base.addingTimeInterval(TimeInterval(minutesDelta * 60))
        firstContactTimeText = Self.timeFormatter.string(from: adjusted)
    }

    // Windows parity: `OpenMessengerAsync` — this view only owns the
    // per-step status text now (`SetMessengerStatus`'s intermediate
    // messages), the actual work is `MissedCallQuickActionService
    // .captureAndUpload`.
    private func runQuickAction(_ messenger: String) {
        messengerBusy[messenger] = true
        messengerFailed[messenger] = false
        messengerStatus[messenger] = "Шукаю номер клієнта в CRM…"
        let currentCrmUrl = crmUrl
        Task {
            let outcome = await MissedCallQuickActionService.captureAndUpload(messenger: messenger, crmUrl: currentCrmUrl)
            messengerBusy[messenger] = false
            switch outcome {
            case .succeeded(let driveUrl):
                messengerScreenshotUrl[messenger] = driveUrl
                messengerStatus[messenger] = driveUrl
                messengerFailed[messenger] = false
            case .cancelled:
                messengerStatus[messenger] = "Скріншот скасовано"
                messengerFailed[messenger] = false
            case .noCrmUrl:
                messengerStatus[messenger] = "Спочатку вкажіть коректне посилання на CRM"
                messengerFailed[messenger] = true
            case .noPhoneFound:
                messengerStatus[messenger] = "Не вдалося знайти номер телефону клієнта в CRM"
                messengerFailed[messenger] = true
            case .couldNotBuildDeepLink:
                messengerStatus[messenger] = "Немає посилання для \(messenger)"
                messengerFailed[messenger] = true
            case .couldNotOpenMessenger:
                messengerStatus[messenger] = "Не вдалося відкрити \(messenger)"
                messengerFailed[messenger] = true
            case .messengerNeverForegrounded:
                messengerStatus[messenger] = "Вікно \(messenger) не з'явилось — скрін не зроблено"
                messengerFailed[messenger] = true
            case .noScreenRecordingPermission:
                messengerStatus[messenger] = "Немає дозволу «Запис екрана» — додай ReplixerMac у Налаштуваннях системи"
                messengerFailed[messenger] = true
            case .captureFailed:
                messengerStatus[messenger] = "Не вдалося зробити скріншот"
                messengerFailed[messenger] = true
            case .uploadFailed:
                messengerStatus[messenger] = "Не вдалося завантажити — спробуйте ще раз"
                messengerFailed[messenger] = true
            }
        }
    }

    // Windows parity: `OnSubmit` — falls back to `missedAt` when the edit
    // block is hidden or its text didn't parse, same as the ViewModel.
    private func submit() {
        let firstContactTime = isNoCommunicationType ? (parsedFirstContactTime ?? missedAt) : missedAt
        let data = MissedCallReportData(
            manager: managerName,
            callType: selectedCallType ?? "",
            crmUrl: crmUrl,
            screenshotUrls: collectScreenshotUrls(),
            firstContactTime: firstContactTime,
            screenshotUrlsByMessenger: messengerScreenshotUrl
        )
        MissedCallReportRequestStore.shared.submit(data)
    }
}
