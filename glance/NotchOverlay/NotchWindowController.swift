//
//  NotchWindowController.swift
//  glance
//
//  Owns the notch overlay window's lifecycle: creation, positioning, show/hide,
//  and SkyLight lock-screen delegation. Knows nothing about face recognition,
//  animation phases, or video playback — NotchOverlayController drives this.
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

    /// Fired on display changes so the overlay controller can re-read `currentGeometry` —
    /// plugging in a notched display can change the panel's shape, not just its width.
    var onScreenParametersChanged: (@MainActor () -> Void)?

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

    /// Creates the window (once), positions and orders it front. If the screen is
    /// actually locked, also delegates it into the SkyLight space — see NotchSkyLight.swift.
    func show() {
        let window = windowIfNeeded()
        reposition(window)
        window.orderFrontRegardless()

        if LockMonitor.isScreenActuallyLocked(), let skyLight = NotchSkyLight.shared {
            skyLight.delegate(window)
            isSkyLightDelegated = true
        }
    }

    /// Forces layout/composite now instead of waiting for the next display cycle —
    /// see `NotchOverlayController.primeWindowIfNeeded`.
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

    /// `key: true` additionally makes the panel key — needed only for onboarding's
    /// password field to receive keystrokes.
    func setInteractive(_ interactive: Bool, key: Bool = false) {
        window?.ignoresMouseEvents = !interactive
        guard interactive, key, let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    var currentGeometry: NotchGeometry {
        NotchGeometry.preferredScreen().map(NotchGeometry.forScreen) ?? NotchGeometry.forMainScreen()
    }

    private func windowIfNeeded() -> NotchWindow {
        if let window { return window }
        // Never resized afterward (see NotchWindow.swift), so a style change
        // mid-session keeps whatever margin it was created with.
        let size = NotchGeometry.windowSize(for: currentGeometry.style)
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
        onScreenParametersChanged?()
        guard let window, window.isVisible else { return }
        reposition(window)
    }
}
