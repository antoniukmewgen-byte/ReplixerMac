import Foundation
import ServiceManagement

/// Phase 8.2 — launch-at-login. Windows-parity source: `AutoStartManager.cs`
/// (`Registry.CurrentUser\...\Run`), but macOS has no registry-run-key
/// equivalent — `SMAppService.mainApp` (macOS 13+) is the modern, sandboxed-
/// friendly replacement: it registers/unregisters *this* app bundle as a
/// login item with launchd, no separate helper-tool bundle or plist needed
/// (that older approach, `SMLoginItemSetEnabled`, is deprecated).
///
/// **Untested assumption, flagged for the first real build/run:**
/// `SMAppService.mainApp` registers the *bundle* launchd resolves the
/// running process back to — this project has no `Info.plist`/bundle
/// identifier of its own yet (it's a bare SwiftPM executable target; Xcode
/// wraps it in a throwaway bundle with an auto-generated identifier when
/// run via a scheme). Whether `register()` succeeds — and whether the
/// resulting login item actually points at something that survives past
/// the current Xcode session — is exactly the kind of "CLI vs bundle"
/// unknown the project plan already calls out; if `register()` throws or
/// silently does nothing useful, the fix is the same one already flagged
/// for Phase 1's TCC prompts: give `ReplixerMacApp` a real `Info.plist`
/// and stable `CFBundleIdentifier` (needed for Phase 9's Sparkle signing
/// anyway) rather than relying on Xcode's throwaway wrapper.
public enum AutoStartManager {
    public enum AutoStartError: Swift.Error {
        case registrationFailed(Swift.Error)
    }

    /// Mirrors `AppSettings.isAutoStartEnabled` into the actual launchd
    /// registration. Throws rather than silently failing so the caller (the
    /// Settings toggle) can show the user *something* went wrong instead of
    /// a toggle that quietly doesn't do what it claims.
    public static func setEnabled(_ enabled: Bool) throws {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            throw AutoStartError.registrationFailed(error)
        }
    }

    /// Ground-truth launchd registration state — not just an echo of
    /// `AppSettings.isAutoStartEnabled`. The two can drift (user removes the
    /// login item via System Settings > General > Login Items directly,
    /// outside this app entirely); reading `SMAppService.mainApp.status`
    /// directly is the same "don't trust a cached flag, ask the OS" stance
    /// as `TelegramAuthClient.hasSavedSession` reading the filesystem
    /// instead of trusting a settings bit.
    public static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }
}
