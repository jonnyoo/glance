//
//  NotchWindowController.swift
//  glance
//
//  Owns the notch overlay window's lifecycle: creation, positioning, and
//  show/hide — including SkyLight delegation so the window is visible on
//  the lock screen for the one trigger (FaceUnlockCoordinator) that needs
//  it there. Knows nothing about face recognition, animation phases, or
//  video playback; NotchOverlayController drives this.
//

import AppKit

@MainActor
final class NotchWindowController {
    private var window: NotchWindow?
    private var isSkyLightDelegated = false

    /// The SwiftUI content to host — set once by NotchOverlayController.
    var contentView: NSView? {
        didSet { window?.contentView = contentView }
    }

    init() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Creates the window (once) at its fixed size, positions it against
    /// the current preferred screen's notch, and orders it front. If the
    /// screen is actually locked right now, also delegates it into the
    /// SkyLight space so it's visible there — see NotchSkyLight.swift.
    func show() {
        let window = windowIfNeeded()
        reposition(window)
        window.orderFrontRegardless()

        if LockMonitor.isScreenActuallyLocked(), let skyLight = NotchSkyLight.shared {
            skyLight.delegate(window)
            isSkyLightDelegated = true
        }
    }

    /// Forces the window to lay out and composite its *current* content
    /// synchronously, rather than waiting for the next display cycle. Used
    /// once, right after the very first `show()`, so there's a real,
    /// already-rendered "closed" frame on screen before anything animates
    /// away from it — see `NotchOverlayController.primeWindowIfNeeded`.
    func displaySynchronously() {
        guard let window else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
    }

    func hide() {
        guard let window else { return }
        if isSkyLightDelegated, let skyLight = NotchSkyLight.shared {
            skyLight.undelegate(window)
            isSkyLightDelegated = false
        }
        window.orderOut(nil)
    }

    /// Toggles whether the overlay accepts clicks. Off for the whole normal
    /// lifecycle; on while a failed attempt waits for a retry tap, or while
    /// onboarding is active.
    ///
    /// `key: true` additionally activates the app and makes the panel the
    /// key window — needed only for onboarding's password field to receive
    /// keystrokes. `NotchWindow.canBecomeKey` already gates on
    /// `!ignoresMouseEvents`, so this is safe to call any time.
    func setInteractive(_ interactive: Bool, key: Bool = false) {
        window?.ignoresMouseEvents = !interactive
        guard interactive, key, let window else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    /// Current geometry for the preferred screen — read by
    /// NotchOverlayView/NotchOverlayController to size the closed/open
    /// silhouette without needing their own screen-selection logic.
    var currentGeometry: NotchGeometry {
        NotchGeometry.preferredScreen().map(NotchGeometry.forScreen) ?? NotchGeometry.forMainScreen()
    }

    private func windowIfNeeded() -> NotchWindow {
        if let window { return window }
        let size = NotchGeometry.windowSize
        let rect = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        let newWindow = NotchWindow(contentRect: rect)
        newWindow.contentView = contentView
        window = newWindow
        return newWindow
    }

    private func reposition(_ window: NotchWindow) {
        guard let screen = NotchGeometry.preferredScreen() else { return }
        let screenFrame = screen.frame
        let size = window.frame.size
        window.setFrameOrigin(NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.maxY - size.height
        ))
    }

    @objc private func screenParametersChanged() {
        guard let window, window.isVisible else { return }
        reposition(window)
    }
}
