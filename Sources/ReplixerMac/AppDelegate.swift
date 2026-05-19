import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Hide dock icon (also set LSUIElement=YES in Info.plist)
        NSApp.setActivationPolicy(.accessory)

        // Request Screen Recording permission early — triggers system dialog if not granted
        Task { @MainActor in
            _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        }

        // Show setup wizard on first launch
        if !AppSettings.shared.isSetupComplete {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.sendAction(Selector(("showSetupWindow:")), to: nil, from: nil)
                // Alternatively open via environment's openWindow — handled in ReplixerApp
                if let env = NSApp.keyWindow?.contentViewController {
                    _ = env // placeholder — SwiftUI openWindow handled at scene level
                }
                NotificationCenter.default.post(name: .showSetup, object: nil)
            }
        } else {
            // Start monitoring immediately if already set up
            Task { @MainActor in
                guard let vm = appViewModel else { return }
                await vm.onAppLaunch()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        appViewModel?.onAppTerminate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSApp.windows.first(where: { $0.identifier?.rawValue == "recordings" })?.makeKeyAndOrderFront(nil) }
        return true
    }

    // Resolved lazily from the SwiftUI environment (set by AppDelegate bridge in practice)
    private var appViewModel: AppViewModel? {
        (NSApp.windows.first?.contentViewController as? NSHostingController<AnyView>)?
            .rootView as? AppViewModel
    }
}

// MARK: - Notifications
extension Notification.Name {
    static let showSetup = Notification.Name("ReplixerShowSetup")
}

// MARK: - ScreenCaptureKit import for permission check
import ScreenCaptureKit
