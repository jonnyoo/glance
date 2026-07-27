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

    func hide() {
        guard let window else { return }
        if isSkyLightDelegated, let skyLight = NotchSkyLight.shared {
            skyLight.undelegate(window)
            isSkyLightDelegated = false
        }
        window.orderOut(nil)
    }

    /// Toggles whether the overlay accepts clicks. Off for the whole normal
    /// lifecycle; on only while a failed attempt waits for a retry tap.
    func setInteractive(_ interactive: Bool) {
        window?.ignoresMouseEvents = !interactive
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
