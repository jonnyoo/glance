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

    /// What the overlay controller asked for via `setInteractive(_:)`.
    private var wantsInteractive = false
    /// The visible panel's frame inside the window, in the hosting view's
    /// top-down coordinates — reported by `NotchOverlayView`.
    private var interactiveContentRect: CGRect?
    /// Re-checks the cursor while `wantsInteractive`; see `updateMousePassthrough()`.
    private var cursorPollTimer: Timer?

    /// Slack around the visible panel before clicks pass through — keeps a
    /// click on the very edge of the shape (or mid hover-bump) from missing.
    private static let interactiveRectOutset: CGFloat = 6

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
        updateCursorPolling()
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
        updateCursorPolling()
    }

    /// `key: true` additionally makes the panel key — needed only for onboarding's
    /// password field to receive keystrokes.
    func setInteractive(_ interactive: Bool, key: Bool = false) {
        wantsInteractive = interactive
        window?.acceptsKey = interactive
        updateCursorPolling()
        guard interactive, key, let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Forwarded from `NotchOverlayView` every time the visible panel's frame changes.
    func setInteractiveContentRect(_ rect: CGRect?) {
        interactiveContentRect = rect
        updateMousePassthrough()
    }

    var currentGeometry: NotchGeometry {
        NotchGeometry.preferredScreen().map(NotchGeometry.forScreen) ?? NotchGeometry.forMainScreen()
    }

    // MARK: - Click-through outside the visible panel

    /// The window's fixed frame is sized for the largest thing it ever shows
    /// (e.g. onboarding's `.enroll` step, plus shadow margin), and `ignoresMouseEvents`
    /// applies to that whole frame — macOS picks which window gets a click from
    /// its frame, not from what's drawn, so a transparent margin still swallows
    /// clicks. Instead of leaving the flag off for as long as the overlay is
    /// interactive, it's only off while the cursor is actually over the panel.
    private func updateMousePassthrough() {
        guard let window else { return }
        guard wantsInteractive else {
            window.ignoresMouseEvents = true
            return
        }
        // Lock screen keeps the original whole-window behaviour: nothing there sits
        // under the notch to click, and hover-to-retry must not regress.
        guard !isSkyLightDelegated, let rect = interactiveContentRect, let hostView = window.contentView else {
            window.ignoresMouseEvents = false
            return
        }
        let windowPoint = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        let local = hostView.convert(windowPoint, from: nil)
        // `rect` is top-down (SwiftUI); normalise the AppKit point to match.
        let topDown = CGPoint(x: local.x, y: hostView.isFlipped ? local.y : hostView.bounds.height - local.y)
        let isOverPanel = rect.insetBy(dx: -Self.interactiveRectOutset, dy: -Self.interactiveRectOutset).contains(topDown)
        if window.ignoresMouseEvents == isOverPanel {
            window.ignoresMouseEvents = !isOverPanel
        }
    }

    /// Polls rather than using mouse-moved events: a window ignoring mouse events
    /// receives none, and a global event monitor doesn't fire for movement over
    /// this app's own windows.
    private func updateCursorPolling() {
        let shouldPoll = wantsInteractive && (window?.isVisible ?? false)
        if shouldPoll, cursorPollTimer == nil {
            let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateMousePassthrough() }
            }
            RunLoop.main.add(timer, forMode: .common)
            cursorPollTimer = timer
        } else if !shouldPoll {
            cursorPollTimer?.invalidate()
            cursorPollTimer = nil
        }
        updateMousePassthrough()
    }

    private func windowIfNeeded() -> NotchWindow {
        if let window { return window }
        // Never resized afterward (see NotchWindow.swift), so it's sized for both
        // styles up front rather than whichever one the screen has right now.
        let size = NotchGeometry.maxWindowSize
        let rect = NSRect(x: 0, y: 0, width: size.width, height: size.height)
        let newWindow = NotchWindow(contentRect: rect)
        newWindow.contentView = contentView
        window = newWindow
        return newWindow
    }

    private func reposition(_ window: NotchWindow) {
        // Only reached once something decided to show the panel (the lock-screen path already bailed on a missing
        // pinned display). Returning here left a panel the user opened at its creation origin (0,0) or on the display
        // that just went away; the same order as `currentGeometry`'s `forMainScreen()` keeps position and shape on one
        // real screen.
        guard let screen = NotchGeometry.preferredScreen()
            ?? NSScreen.screens.first(where: { $0.isBuiltIn })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        else { return }
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
