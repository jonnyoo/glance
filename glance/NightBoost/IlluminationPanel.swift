//
//  IlluminationPanel.swift
//  glance
//
//  The "flood light": a borderless, click-through panel that paints the upper part of the screen a warm near-white while
//  a dark-room scan runs. Warm rather than pure white on purpose — the glare deny cue only counts near-*grey* highlights
//  (luma ≥ 235 AND |Cb-128|, |Cr-128| ≤ 10 — GlareCueExtractor.swift:12-13), so a warm reflection off glasses or a
//  forehead stays chromatic and is not mistaken for the screen glare that betrays a spoof.
//
//  The failure this avoids is a false DENY of a live user, not a false accept: a tripped glare cue latches for the whole
//  scan (LivenessCues.swift:173,227), so one bright reflection would reject a real face for all 5 seconds.
//

import AppKit

final class IlluminationPanel: NSPanel {
    /// Warm white, roughly 3000K. Measured against `GlareCueExtractor` with a 2%-of-crop highlight: pure white denies at
    /// 1.0x reflection gain (i.e. always), this colour not until 1.60x — the point where all three channels finally clip
    /// to neutral. Warmer still keeps buying headroom (0.75/0.45 reaches 2.05x) but casts far enough off-white to risk
    /// costing ArcFace similarity against a daylight-enrolled template, which is the same annoyance from the other side.
    static let lightColor = NSColor(srgbRed: 1.0, green: 0.84, blue: 0.58, alpha: 1.0)

    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = Self.lightColor
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        alphaValue = 0
        // One below the notch panel (.mainMenu + 3) so the scan animation stays on top of the light.
        level = .mainMenu + 2
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
