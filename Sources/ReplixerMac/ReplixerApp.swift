import SwiftUI

@main
struct ReplixerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appVM = AppViewModel()

    var body: some Scene {
        // Menu bar icon + popover
        MenuBarExtra {
            MenuBarView()
                .environmentObject(appVM)
        } label: {
            let isRecording = appVM.activeSession != nil
            Label(
                isRecording ? "Запис…" : "Replixer",
                systemImage: isRecording ? "record.circle.fill" : "waveform"
            )
        }
        .menuBarExtraStyle(.window)

        // Recordings window (cmd+1 or via popover button)
        Window("Записи", id: "recordings") {
            RecordingsView()
                .environmentObject(appVM)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 560)
        .defaultPosition(.center)

        // Setup wizard (shown on first launch)
        Window("Налаштування Replixer", id: "setup") {
            SetupView(
                vm: SetupViewModel(
                    settings: .shared,
                    telegramAuth: appVM.telegramAuth,
                    driveService: appVM.driveService
                )
            )
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        // Settings window (standard macOS Preferences style)
        Settings {
            SettingsView()
                .environmentObject(appVM)
        }
    }
}
