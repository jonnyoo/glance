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

        ignoresMouseEvents = true
    }

    enum Interaction {
        case none, hover, controls
    }

    weak var interactionRegion: NotchInteractionRegion.RegionView?
    var interaction: Interaction = .none {
        didSet {
            if interaction != .controls { pressedButtons.removeAll() }
            updatePointer()
        }
    }
    private var pointerTimer: Timer?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private var isHovering = false
    private var pressedButtons: Set<Int> = []

    /// Hover observation does not require the window to intercept clicks.
    /// The timer also handles a stationary pointer while the panel animates.
    func startPointerTracking() {
        guard pointerTimer == nil else { return }
        let moves: NSEvent.EventTypeMask = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: moves) { [weak self] _ in
            self?.updatePointer()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: moves) { [weak self] event in
            self?.updatePointer()
            return event
        }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updatePointer() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
        updatePointer()
    }

    func stopPointerTracking() {
        pointerTimer?.invalidate()
        pointerTimer = nil
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        localMonitor = nil
        globalMonitor = nil
        pressedButtons.removeAll()
        ignoresMouseEvents = true
        setHovering(false)
    }

    func updatePointer(at screenPoint: NSPoint = NSEvent.mouseLocation) {
        let inside = isVisible && interactionRegion?.contains(screenPoint: screenPoint) == true
        ignoresMouseEvents = interaction != .controls || (!inside && pressedButtons.isEmpty)
        setHovering(interaction != .none && inside)
    }

    private func setHovering(_ hovering: Bool) {
        guard hovering != isHovering else { return }
        isHovering = hovering
        interactionRegion?.onHover?(hovering)
    }

    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            pressedButtons.insert(event.buttonNumber)
        case .leftMouseUp, .rightMouseUp, .otherMouseUp:
            pressedButtons.remove(event.buttonNumber)
        default: break
        }
        super.sendEvent(event)
        updatePointer()
    }

    // Keyboard focus must survive moving the pointer out of a password field.
    override var canBecomeKey: Bool { interaction == .controls }
    override var canBecomeMain: Bool { false }
}
