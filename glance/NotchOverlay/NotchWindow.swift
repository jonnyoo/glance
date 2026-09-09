//
//  NotchWindow.swift
//  glance
//
//  Borderless, transparent, click-through panel. Created once and never resized —
//  all expansion/collapse is SwiftUI animating content inside this fixed window
//  (never call setFrame/setContentSize on it; only setFrameOrigin, to reposition).
//

import AppKit

final class NotchWindow: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        level = .mainMenu + 3
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

        // Decorative by default — clicks pass through until a failed attempt is
        // waiting to be tapped for retry (see NotchWindowController.setInteractive).
        ignoresMouseEvents = true
    }

    /// Must become key while interactive or the tap-to-retry gesture never receives
    /// the click; never becomes main, so it doesn't take over as the app's primary window.
    override var canBecomeKey: Bool { !ignoresMouseEvents }
    override var canBecomeMain: Bool { false }
}
