import SwiftUI
import AppKit

/// Forces the app to actually take keyboard focus on launch.
///
/// Root cause of "cursor blinks in the TextField but keystrokes land in
/// Xcode": `ReplixerMacApp` is a raw SwiftPM executable, not a proper
/// Launch-Services-registered `.app` bundle opened via Finder/Dock/`open`.
/// Apps launched that way (including "spawned directly by Xcode's
/// debugger", which is what happens here) don't get the automatic
/// frontmost-activation that Finder-launched apps get for free — the
/// process runs, its window draws and can be clicked, but the *key
/// (frontmost) application* at the OS level stays Xcode, so all keyboard
/// events keep routing there regardless of which window looks focused.
/// `NSApp.activate(ignoringOtherApps:)` explicitly steals that focus; must
/// run from `applicationDidFinishLaunching` (not the App struct's own
/// `init()`, which fires before `NSApplication`'s run loop — and therefore
/// before there's anything to activate — is actually spun up).
private final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

@main
struct ReplixerMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 700, minHeight: 450)
        }
    }
}
