//
//  NotchWindow.swift
//  glance
//
//  Borderless, transparent, click-through panel. Created once at
//  `NotchGeometry.windowSize(for:)` and never resized — the spike (Phase 0)
//  confirmed standard AppKit window levels are NOT visible on the real
//  lock screen, so `NotchSkyLight` is used to bridge that gap, toggled on
//  only while the screen is actually locked.
//
//  All expansion/collapse is SwiftUI animating content inside this fixed
//  window — the single most important technique borrowed from studying
//  Boring Notch's architecture (never call setFrame/setContentSize on this
//  window; only setFrameOrigin, to reposition it).
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

        // Decorative by default — clicks pass straight through. Flipped on
        // only while a failed attempt is waiting to be tapped for retry
        // (see NotchWindowController.setInteractive).
        ignoresMouseEvents = true
    }

    /// Must be able to become key while interactive, otherwise the tap-to-
    /// retry gesture never receives the click. Still never becomes *main*,
    /// so it doesn't take over as the app's primary window.
    override var canBecomeKey: Bool { !ignoresMouseEvents }
    override var canBecomeMain: Bool { false }
}
