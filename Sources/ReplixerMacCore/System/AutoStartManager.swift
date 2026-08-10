import Foundation
import ServiceManagement

/// Phase 8.2 — launch-at-login. Windows-parity source: `AutoStartManager.cs`
/// (`Registry.CurrentUser\...\Run`), but macOS has no registry-run-key
/// equivalent — `SMAppService.mainApp` (macOS 13+) is the modern, sandboxed-
/// friendly replacement: it registers/unregisters *this* app bundle as a
/// login item with launchd, no separate helper-tool bundle or plist needed
/// (that older approach, `SMLoginItemSetEnabled`, is deprecated).
///
/// **Confirmed on a real build (Phase 8.2), not just a theoretical risk:**
/// `SMAppService.mainApp.register()` threw `SMAppServiceErrorDomain Code=1
/// "Operation not permitted"` when run as a bare SwiftPM executable via
/// Xcode's debug session — `SMAppService.mainApp` needs a real, stably-
/// located `Contents/Info.plist` + `Contents/MacOS/<exe>` bundle to
/// register a login item against; a process running straight out of a
/// throwaway `DerivedData` path (which is all Xcode gives a plain
/// executable target while debugging) doesn't qualify, regardless of
/// whether the process's own Mach-O carries an embedded Info.plist section
/// (Phase 8.3 added exactly that, via Package.swift's `__info_plist`
/// linker section — it fixes `LSUIElement`/TCC descriptions, which the OS
/// reads straight off the running process, but it does NOT fix this: this
/// call also drags in launchd/LaunchServices, which resolve against real
/// on-disk bundle paths, not linker sections).
///
/// **Fix, and how to test it:** `Scripts/build-app-bundle.sh` packages a
/// real `ReplixerMac.app` (ad-hoc signed, no paid Apple Developer account
/// needed — see that script's own comment for why ad-hoc is sufficient
/// here) — copy/symlink the result into `/Applications` and toggle
/// autostart from *that* running copy, not from an Xcode debug session,
/// which will still hit the same "Operation not permitted" error no matter
/// how complete `Info.plist` gets.
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
