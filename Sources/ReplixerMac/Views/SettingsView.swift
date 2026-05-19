import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var appVM: AppViewModel
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        TabView {
            GeneralSettingsTab(settings: settings)
                .tabItem { Label("Загальні", systemImage: "gearshape") }

            DetectionSettingsTab(settings: settings)
                .tabItem { Label("Детекція", systemImage: "waveform.badge.magnifyingglass") }

            AccountsTab(appVM: appVM, settings: settings)
                .tabItem { Label("Акаунти", systemImage: "person.2") }
        }
        .padding()
        .frame(width: 500)
    }
}

// MARK: - General
private struct GeneralSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            TextField("Ім'я менеджера", text: $settings.managerName)
            TextField("ID папки Google Drive", text: $settings.googleDriveFolderId)
            Toggle("Google Drive увімкнено", isOn: $settings.isGoogleDriveEnabled)
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Detection
private struct DetectionSettingsTab: View {
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Поріг рівня звуку") {
                HStack {
                    Slider(value: $settings.callStartThresholdDB, in: -70 ... -10, step: 1)
                    Text("\(Int(settings.callStartThresholdDB)) дБ")
                        .frame(width: 50)
                        .monospacedDigit()
                }
                Text("Рівень звуку вище цього порогу вважається дзвінком.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Таймаути (секунди)") {
                HStack {
                    Text("Підтвердження початку:")
                    Spacer()
                    Stepper("\(settings.callStartConfirmSeconds, specifier: "%.0f") с",
                            value: $settings.callStartConfirmSeconds, in: 1...10, step: 1)
                }
                HStack {
                    Text("Тиша до завершення:")
                    Spacer()
                    Stepper("\(settings.callEndSilenceSeconds, specifier: "%.0f") с",
                            value: $settings.callEndSilenceSeconds, in: 1...15, step: 1)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Accounts
private struct AccountsTab: View {
    @ObservedObject var appVM: AppViewModel
    @ObservedObject var settings: AppSettings

    var body: some View {
        Form {
            Section("Telegram") {
                if settings.isTelegramAuthorized {
                    HStack {
                        Label("Авторизовано", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Spacer()
                        Button("Вийти") { Task { await appVM.telegramAuth.logOut() } }
                            .buttonStyle(.bordered)
                            .tint(.red)
                    }
                    TextField("Chat ID", value: $settings.telegramChatId, format: .number)
                } else {
                    Label("Не авторизовано", systemImage: "xmark.seal")
                        .foregroundStyle(.secondary)
                }
            }

            Section("API Credentials") {
                TextField("api_id", value: $settings.telegramApiId, format: .number)
                SecureField("api_hash", text: $settings.telegramApiHash)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
