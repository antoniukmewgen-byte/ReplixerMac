import AppKit
import Foundation

/// Windows parity source: `ViewModels/Dialogs/MissedCallReportViewModel
/// .OpenMessengerAsync` — the full pipeline behind `MissedCallReportView`'s
/// per-messenger "quick action" buttons: resolve the client's phone number
/// from Kommo, open a deep link into the messenger app, wait for it to come
/// to the foreground, let the manager drag a screenshot selection, capture
/// + upload it, and hand back a Drive link to embed in the report.
///
/// Deliberately scoped down for mac's v1 (see `MissedCallReportView`'s doc
/// comment for the full reasoning):
/// - No "pin window topmost, read its exact rect" step before showing the
///   selection overlay — Windows uses `GetWindowRect` on the just-
///   foregrounded messenger window to pre-seed `ScreenshotSelectionWindow`'s
///   initial rectangle; `ScreenshotSelectionOverlay` always starts blank
///   (it has no "seed" API to begin with — see that type's doc comment) and
///   the manager drags freehand instead.
/// - A failed upload also gets queued for background retry (see
///   `ScreenshotUploadRetryService`, Windows parity: enqueuing into
///   `PendingScreenshotUploadRetryService`) — `.uploadFailed` still surfaces
///   immediately so the manager sees the error right away, but doesn't need
///   to re-click the button for the link to eventually land.
/// - Screenshots go through `GoogleDriveUploadService.resolveScreenshotsFolder()`,
///   Windows parity: `MissedCallReportViewModel.ResolveScreenshotFolderIdAsync`
///   / `GetOrCreateUserFolderAsync` — creates/finds a "Screenshots" subfolder
///   inside the per-manager folder (itself created inside
///   `AppSettings.shared.googleDriveFolderId`). Unlike Windows, the resolved
///   id isn't cached in a view-model field across multiple button taps in
///   the same dialog session — it's re-resolved per tap, which after the
///   first tap is a cheap cache hit anyway since `resolveManagerFolder()`
///   persists its own result in `AppSettings.shared.googleDriveUserFolderId`.
public enum MissedCallQuickActionService {
    public enum Outcome {
        /// Captured and uploaded — `driveUrl` is what
        /// `MissedCallReportView` stores into
        /// `MissedCallReportData.screenshotUrls`/`screenshotUrlsByMessenger`.
        case succeeded(driveUrl: String)
        /// The manager cancelled the selection overlay (Escape, or a click
        /// that never became a real drag) — not an error, just "nothing
        /// happened", same as Windows' selection window returning a null
        /// rect.
        case cancelled
        case noCrmUrl
        case noPhoneFound
        case couldNotBuildDeepLink
        case couldNotOpenMessenger
        /// The messenger never came to the foreground within the timeout —
        /// Windows parity: `WaitForMessengerForegroundAsync` returning
        /// false.
        case messengerNeverForegrounded
        case noScreenRecordingPermission
        case captureFailed
        case uploadFailed(String)
    }

    // Windows parity: `WaitForMessengerForegroundAsync`'s exact 10s
    // timeout / 150ms poll interval.
    private static let foregroundTimeoutSeconds: TimeInterval = 10
    private static let foregroundPollNanoseconds: UInt64 = 150_000_000

    /// Runs the full pipeline for one messenger button tap. `crmUrl` is
    /// read straight off the in-progress form field, not a submitted
    /// report — same as Windows' `OpenMessengerAsync` reading `_data.CrmUrl`
    /// directly off the still-open dialog.
    @MainActor
    public static func captureAndUpload(messenger: String, crmUrl: String) async -> Outcome {
        let trimmedCrmUrl = crmUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCrmUrl.isEmpty else { return .noCrmUrl }

        // Fail fast rather than letting the manager go through the whole
        // deep-link/foreground-wait dance only to hit a black/empty capture
        // at the very end — same reasoning as this permission check's doc
        // comment on `ScreenCaptureService`.
        guard ScreenCaptureService.hasScreenRecordingPermission() else {
            ScreenCaptureService.requestScreenRecordingPermission()
            return .noScreenRecordingPermission
        }

        guard let phone = await KommoService.getClientPhone(leadUrl: trimmedCrmUrl) else {
            return .noPhoneFound
        }
        guard let deepLink = MessengerDeepLinkProvider.buildDeepLink(messenger: messenger, phone: phone) else {
            return .couldNotBuildDeepLink
        }
        guard NSWorkspace.shared.open(deepLink) else {
            return .couldNotOpenMessenger
        }

        guard await waitForMessengerForeground(messenger) else {
            return .messengerNeverForegrounded
        }

        guard let region = await ScreenshotSelectionOverlay.select() else {
            return .cancelled
        }

        guard let filePath = await ScreenCaptureService.captureRegion(region, messenger: messenger) else {
            return .captureFailed
        }

        guard let folderId = await GoogleDriveUploadService.resolveScreenshotsFolder() else {
            // Folder resolution itself failed — the capture is still a real
            // file on disk, so queue it anyway (with a nil folder id;
            // ScreenshotUploadRetryService re-resolves it on each retry).
            ScreenshotUploadRetryService.shared.enqueue(localPath: filePath, folderId: nil, messenger: messenger, kommoLeadUrl: trimmedCrmUrl)
            return .uploadFailed("googleDriveFolderId не налаштовано")
        }
        do {
            let driveUrl = try await GoogleDriveUploadService.upload(filePath: filePath, folderId: folderId)
            return .succeeded(driveUrl: driveUrl)
        } catch {
            ScreenshotUploadRetryService.shared.enqueue(localPath: filePath, folderId: folderId, messenger: messenger, kommoLeadUrl: trimmedCrmUrl)
            return .uploadFailed("\(error)")
        }
    }

    /// Windows parity source: `MissedCallReportViewModel
    /// .WaitForMessengerForegroundAsync` — same poll shape, just checking
    /// `NSWorkspace.shared.frontmostApplication` instead of Win32's
    /// foreground-window handle. Substring match against `localizedName`
    /// mirrors `SupportedMessenger.matching(processName:)`'s idiom
    /// (`MessengerDeepLinkProvider.supportedMessengers`' three names are a
    /// deliberately smaller list than `SupportedMessenger`'s four cases —
    /// see that provider's doc comment — so this checks the raw string
    /// directly rather than routing through the enum).
    private static func waitForMessengerForeground(_ messenger: String) async -> Bool {
        let deadline = Date().addingTimeInterval(foregroundTimeoutSeconds)
        while Date() < deadline {
            if let name = NSWorkspace.shared.frontmostApplication?.localizedName,
               name.localizedCaseInsensitiveContains(messenger) {
                return true
            }
            try? await Task.sleep(nanoseconds: foregroundPollNanoseconds)
        }
        return false
    }
}
