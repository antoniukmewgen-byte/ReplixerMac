import SwiftUI

struct SetupView: View {
    @StateObject var vm: SetupViewModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header / step indicator
    private var header: some View {
        HStack(spacing: 0) {
            ForEach(SetupViewModel.Step.allCases.dropLast(), id: \.self) { step in
                stepIndicator(step)
                if step != .drive { stepConnector(step) }
            }
        }
        .padding()
    }

    private func stepIndicator(_ step: SetupViewModel.Step) -> some View {
        let current = vm.currentStep.rawValue
        let target  = step.rawValue
        let isDone  = current > target
        let isNow   = current == target

        return VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(isDone ? Color.accentColor : (isNow ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.15)))
                    .frame(width: 32, height: 32)
                if isDone {
                    Image(systemName: "checkmark").foregroundStyle(.white).bold()
                } else {
                    Text("\(target + 1)")
                        .font(.callout.bold())
                        .foregroundStyle(isNow ? .accent : .secondary)
                }
            }
            Text(step.title)
                .font(.caption2)
                .foregroundStyle(isNow ? .primary : .secondary)
        }
    }

    private func stepConnector(_ step: SetupViewModel.Step) -> some View {
        Rectangle()
            .fill(vm.currentStep.rawValue > step.rawValue ? Color.accentColor : Color.secondary.opacity(0.3))
            .frame(height: 2)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Step content
    @ViewBuilder
    private var content: some View {
        Group {
            switch vm.currentStep {
            case .manager:   ManagerStep(vm: vm)
            case .telegram:  TelegramStep(vm: vm)
            case .drive:     DriveStep(vm: vm)
            case .done:      DoneStep()
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Footer
    private var footer: some View {
        HStack {
            if vm.currentStep.rawValue > 0 && vm.currentStep != .done {
                Button("Назад") { vm.goBack() }
                    .buttonStyle(.bordered)
            }
            Spacer()
            if vm.currentStep == .done {
                Button("Почати роботу") { vm.finish() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!vm.canProceedFromManager)
            } else if vm.currentStep == .manager {
                Button("Далі") { vm.goNext() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!vm.canProceedFromManager)
            } else {
                Button("Пропустити") { vm.goNext() }
                    .buttonStyle(.bordered)
                Button("Далі") { vm.goNext() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding()
    }
}

// MARK: - Step 1: Manager name
private struct ManagerStep: View {
    @ObservedObject var vm: SetupViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepTitle("Ваш профіль", icon: "person.circle")
            Text("Ім'я менеджера буде додано до назви кожного запису та папки на Google Drive.")
                .foregroundStyle(.secondary)
            TextField("Ім'я та прізвище", text: $vm.managerNameInput)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
        }
    }
}

// MARK: - Step 2: Telegram
private struct TelegramStep: View {
    @ObservedObject var vm: SetupViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepTitle("Telegram (MTProto)", icon: "paperplane.circle")
            Text("Отримайте api_id та api_hash на **my.telegram.org/apps**. Це необхідно для повноцінного MTProto клієнта.")
                .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                VStack(alignment: .leading) {
                    Text("api_id").font(.caption).foregroundStyle(.secondary)
                    TextField("12345678", text: $vm.telegramApiId)
                        .textFieldStyle(.roundedBorder)
                }
                VStack(alignment: .leading) {
                    Text("api_hash").font(.caption).foregroundStyle(.secondary)
                    SecureField("abc123…", text: $vm.telegramApiHash)
                        .textFieldStyle(.roundedBorder)
                }
            }

            Divider()

            authStateView
        }
    }

    @ViewBuilder
    private var authStateView: some View {
        switch vm.telegramAuth.authState {
        case .idle:
            Button("Авторизуватися") { vm.startTelegramAuth() }
                .buttonStyle(.borderedProminent)
                .disabled(vm.telegramApiId.isEmpty || vm.telegramApiHash.isEmpty)

        case .waitingPhone:
            VStack(alignment: .leading, spacing: 8) {
                Text("Введіть номер телефону (міжнародний формат)").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("+380XXXXXXXXX", text: $vm.phoneInput)
                        .textFieldStyle(.roundedBorder)
                    Button("Надіслати") { Task { await vm.submitPhone() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.phoneInput.isEmpty)
                }
            }

        case .waitingCode:
            VStack(alignment: .leading, spacing: 8) {
                Text("Введіть код із Telegram").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("12345", text: $vm.codeInput)
                        .textFieldStyle(.roundedBorder)
                    Button("Підтвердити") { Task { await vm.submitCode() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.codeInput.isEmpty)
                }
            }

        case .waitingPassword:
            VStack(alignment: .leading, spacing: 8) {
                Text("Двоетапна перевірка — введіть пароль").font(.caption).foregroundStyle(.secondary)
                HStack {
                    SecureField("Пароль", text: $vm.passwordInput)
                        .textFieldStyle(.roundedBorder)
                    Button("Підтвердити") { Task { await vm.submitPassword() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(vm.passwordInput.isEmpty)
                }
            }

        case .ready:
            Label("Авторизовано ✓", systemImage: "checkmark.seal.fill")
                .foregroundStyle(.green)
                .font(.headline)

        case .error(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.caption)
        }
    }
}

// MARK: - Step 3: Google Drive
private struct DriveStep: View {
    @ObservedObject var vm: SetupViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepTitle("Google Drive", icon: "externaldrive.badge.cloud")
            Text("Помістіть **service_account.json** поряд із додатком, потім вкажіть ID спільної папки.")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("ID папки").font(.caption).foregroundStyle(.secondary)
                HStack {
                    TextField("1BxiMVs0XRA5nFMdKvBdBZjgmUUqptlbs…", text: $vm.folderId)
                        .textFieldStyle(.roundedBorder)
                    Button("Перевірити") { Task { await vm.testDriveAccess() } }
                        .buttonStyle(.bordered)
                        .disabled(vm.folderId.isEmpty || vm.isTestingDrive)
                }
            }

            if vm.isTestingDrive {
                ProgressView("Перевірка доступу…")
            } else if let result = vm.driveTestResult {
                Text(result)
                    .font(.caption)
                    .foregroundStyle(result.hasPrefix("✓") ? Color.green : Color.red)
            }
        }
    }
}

// MARK: - Step 4: Done
private struct DoneStep: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(.green)
            Text("Все готово!")
                .font(.title.bold())
            Text("Натисніть «Почати роботу», щоб відкрити головне вікно.\nReplixer розпочне моніторинг VoIP-дзвінків у фоні.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
        }
        .padding()
    }
}

// MARK: - Shared
private func stepTitle(_ text: String, icon: String) -> some View {
    Label(text, systemImage: icon)
        .font(.title2.bold())
}
