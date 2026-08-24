import AppKit

/// Windows parity source: `Services/ScreenshotFeedbackService.cs` +
/// `Views/ScreenshotFlashWindow.xaml(.cs)` + `Infrastructure
/// /ScreenshotFlashInterop.cs` — a short sound plus a full-screen flash the
/// instant `ScreenCaptureService` grabs a frame, so the manager gets some
/// confirmation "the screenshot happened" even when the messenger window
/// (Telegram/Viber/WhatsApp) is covering the whole screen and no other part
/// of Replixer is visible. Purely cosmetic feedback — capture/save already
/// succeeded by the time this runs, so any failure here is swallowed, not
/// thrown.
public enum ScreenshotFeedbackService {
    @MainActor
    public static func flash() {
        // "Glass" is the closest built-in NSSound to Windows'
        // SystemSounds.Asterisk — a short, non-alarming confirmation tone.
        NSSound(named: "Glass")?.play()
        FlashWindow.show()
    }
}

/// One-shot, self-closing overlay window. Kept as a static var (mirrors
/// `ScreenshotSelectionOverlay`'s `activeController` pattern) because AppKit
/// won't retain a programmatically-created, controller-less `NSWindow` on
/// its own — without this it would be deallocated (and vanish) before the
/// fade-out animation finishes.
@MainActor
private final class FlashWindow {
    private static var active: NSWindow?

    static func show() {
        // Union of every screen (not just `.main`), same reasoning as
        // `ScreenshotSelectionOverlay`: the flash needs to be visible
        // regardless of which monitor the messenger is on.
        let unionFrame = NSScreen.screens.reduce(CGRect.null) { $0.union($1.frame) }
        guard !unionFrame.isNull, unionFrame.width > 0, unionFrame.height > 0 else { return }

        let window = NSWindow(
            contentRect: unionFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver // above everything, including the menu bar
        // Click-through: the WS_EX_TRANSPARENT equivalent from
        // ScreenshotFlashInterop.cs — a stray click/move during the 450ms
        // flash must reach the messenger window underneath, not this overlay.
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]

        let view = FlashView(frame: NSRect(origin: .zero, size: unionFrame.size))
        window.contentView = view

        active = window
        window.orderFrontRegardless()
        view.animateAndClose {
            active?.orderOut(nil)
            active = nil
        }
    }
}

/// Draws the same "#22C679 border + faint fill" green rectangle as Windows'
/// `ScreenshotFlashWindow.xaml`, driven by a `CAKeyframeAnimation` instead of
/// WPF's `DoubleAnimationUsingKeyFrames` — same timing: 0→1 opacity over
/// 90ms, hold to 220ms, fade to 0 by 450ms.
private final class FlashView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedRed: 0x22 / 255, green: 0xC6 / 255, blue: 0x79 / 255, alpha: 0.1647).cgColor
        layer?.borderColor = NSColor(calibratedRed: 0x22 / 255, green: 0xC6 / 255, blue: 0x79 / 255, alpha: 1).cgColor
        layer?.borderWidth = 10
        layer?.opacity = 0
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func animateAndClose(completion: @escaping () -> Void) {
        guard let layer else {
            completion()
            return
        }
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [0, 1, 1, 0]
        animation.keyTimes = [0, 0.2, 0.489, 1] // 90ms / 220ms / 450ms of a 450ms total
        animation.duration = 0.45
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false

        CATransaction.begin()
        CATransaction.setCompletionBlock(completion)
        layer.add(animation, forKey: "flash")
        CATransaction.commit()
    }
}
