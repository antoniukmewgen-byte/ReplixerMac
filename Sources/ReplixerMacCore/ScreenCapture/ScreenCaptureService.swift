import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ScreenCaptureKit

/// macOS-native counterpart of Windows' `Services/ScreenCaptureService.cs`
/// (BitBlt-based window/region capture) — no direct code-reuse is possible
/// (GDI/BitBlt has no macOS equivalent), so this ports the *intent* instead:
/// "screenshot a caller-supplied screen rectangle, save as PNG under a
/// `Screenshots` folder, name it `{Messenger}_{dd.MM.yyyy_HH-mm}[_N].png`".
///
/// Uses ScreenCaptureKit's `SCScreenshotManager.captureImage` (macOS 14+ —
/// safe unconditionally since this package's deployment target is already
/// `.macOS("14.2")`, raised for `AudioHardwareCreateProcessTap`, see
/// `Package.swift`) rather than the older, Apple-deprecated
/// `CGWindowListCreateImage` — the same "naive capture API silently returns
/// a black/empty frame against a modern hardware-composited window" failure
/// mode Windows' own doc comment on `ScreenCaptureService.cs` describes
/// PrintWindow hitting for UWP/Store apps, just macOS's version of it.
///
/// Deliberately scoped down vs. Windows (v1 of the missed-call screenshot
/// flow, see `MissedCallReportView`'s doc comment): only region capture is
/// ported (`CaptureRegion`), not `CaptureForegroundWindow` — the manager
/// always drags a rectangle via `ScreenshotSelectionOverlay` regardless of
/// whether it was pre-seeded from a window's bounds, since mac's v1 flow
/// has no "pin window topmost, read its exact rect" step (see
/// `MissedCallReportView`'s doc comment on why).
public enum ScreenCaptureService {
    private static let screenshotsDir: URL =
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReplixerMac", isDirectory: true)
            .appendingPathComponent("Screenshots", isDirectory: true)

    /// Windows has no equivalent gate — BitBlt just works there. macOS
    /// requires the user grant the "Screen Recording" TCC permission before
    /// any capture API (ScreenCaptureKit included) returns real pixels;
    /// checking this up front lets `MissedCallReportView` show a clear
    /// message instead of a silent black/empty screenshot. No
    /// `Info.plist` usage-description string is needed for Screen Recording
    /// (unlike camera/mic) — the system prompt text is fixed by macOS
    /// itself.
    public static func hasScreenRecordingPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// Triggers the system's Screen Recording permission prompt if the app
    /// hasn't been asked (or denied) yet. Returns immediately — macOS has no
    /// synchronous "block until the user answers" API here, so callers
    /// should re-check `hasScreenRecordingPermission()` afterwards (same
    /// "prompt, then re-check" shape as this app's existing mic-permission
    /// handling).
    @discardableResult
    public static func requestScreenRecordingPermission() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// Captures `region` (screen points, `NSScreen`/AppKit's bottom-left-
    /// origin coordinate space — the same space `ScreenshotSelectionOverlay`
    /// reports its selection in) and saves it as a PNG under `Screenshots/`.
    /// `messenger` ("Viber"/"Telegram"/"WhatsApp") feeds the saved file's
    /// name, same reasoning as Windows' `CaptureRegion` — so a file uploaded
    /// to Google Drive reads as e.g. "Telegram_23.04.2026_15-34.png" rather
    /// than an anonymous timestamp.
    ///
    /// Returns the saved file's path, or `nil` if permission/capture/save
    /// failed — every failure reason is logged, not thrown, same "return
    /// nil, log the rest" contract as Windows' `CaptureRegion`.
    public static func captureRegion(_ region: CGRect, messenger: String) async -> String? {
        guard region.width > 0, region.height > 0 else { return nil }
        guard hasScreenRecordingPermission() else {
            print("[ScreenCaptureService] ❌ немає дозволу «Запис екрана» — відкрий Налаштування системи → Конфіденційність і безпека → Запис екрана і додай ReplixerMac.")
            return nil
        }

        guard let screen = NSScreen.screens.first(where: { $0.frame.intersects(region) }) ?? NSScreen.main,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            print("[ScreenCaptureService] ❌ не вдалося визначити дисплей для області захвату \(region).")
            return nil
        }

        do {
            let content = try await SCShareableContent.current
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                print("[ScreenCaptureService] ❌ дисплей \(displayID) не знайдено серед SCShareableContent.current.displays.")
                return nil
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])

            // NSScreen.frame is bottom-left-origin (AppKit convention);
            // SCStreamConfiguration.sourceRect is top-left-origin, relative
            // to the display's own frame (ScreenCaptureKit convention) —
            // flip the y-axis and re-base onto the display's own origin
            // (multi-monitor setups can have negative/offset origins).
            let displayFrame = screen.frame
            let localRect = CGRect(
                x: region.origin.x - displayFrame.origin.x,
                y: displayFrame.height - (region.origin.y - displayFrame.origin.y) - region.height,
                width: region.width,
                height: region.height
            )

            let configuration = SCStreamConfiguration()
            configuration.sourceRect = localRect
            // Physical pixels, not points — otherwise a Retina capture comes
            // back soft/upscaled.
            configuration.width = max(1, Int(region.width * screen.backingScaleFactor))
            configuration.height = max(1, Int(region.height * screen.backingScaleFactor))
            configuration.showsCursor = false

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            return save(image, messenger: messenger)
        } catch {
            print("[ScreenCaptureService] ❌ захват екрана не вдався: \(error)")
            return nil
        }
    }

    private static func save(_ image: CGImage, messenger: String) -> String? {
        do {
            try FileManager.default.createDirectory(at: screenshotsDir, withIntermediateDirectories: true)
        } catch {
            print("[ScreenCaptureService] ❌ не вдалося створити \(screenshotsDir.path): \(error)")
            return nil
        }

        let path = buildScreenshotPath(messenger: messenger)
        let url = URL(fileURLWithPath: path)

        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            print("[ScreenCaptureService] ❌ не вдалося створити PNG-призначення для \(path).")
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            print("[ScreenCaptureService] ❌ не вдалося зберегти PNG у \(path).")
            return nil
        }
        return path
    }

    /// Windows parity source: `ScreenCaptureService.BuildScreenshotPath` —
    /// same "Messenger_dd.MM.yyyy_HH-mm[_N].png" format and collision
    /// suffixing. ":" isn't illegal in an APFS filename the way it is on
    /// NTFS, but the format is kept identical anyway for consistency with
    /// what ends up in Google Drive/Kommo note text on either platform.
    private static func buildScreenshotPath(messenger: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy_HH-mm"
        let baseName = "\(messenger)_\(formatter.string(from: Date()))"

        var path = screenshotsDir.appendingPathComponent("\(baseName).png").path
        var suffix = 2
        while FileManager.default.fileExists(atPath: path) {
            path = screenshotsDir.appendingPathComponent("\(baseName)_\(suffix).png").path
            suffix += 1
        }
        return path
    }
}
