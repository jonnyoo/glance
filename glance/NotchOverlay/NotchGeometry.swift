//
//  NotchGeometry.swift
//  glance
//
//  Pure geometry — no AppKit window knowledge. Computes where the physical
//  (or synthetic) notch sits on a given screen and how big the overlay
//  window should be, so NotchWindowController just asks "where" and "how
//  big" without knowing how those numbers were derived.
//

import AppKit
import CoreGraphics

struct NotchGeometry {
    /// Size of the closed (collapsed) notch silhouette, in the screen's own
    /// point space.
    let closedSize: CGSize
    /// True if this screen has a real physical notch (vs. the synthetic
    /// fallback drawn for external/non-notched displays).
    let isPhysicalNotch: Bool

    /// Fixed footprint the scan-mode overlay content (armed lock-screen
    /// flow, Face Lab previews) animates within when expanded. Sized for
    /// the square (432x432) scan animation plus breathing room — onboarding
    /// does not use this; see OnboardingMetrics for its per-step sizes.
    static let openSize = CGSize(width: 240, height: 220)

    /// Corner radii for the notch silhouette. The top radius doubles as the
    /// width of the outward flare on each side (see NotchShape).
    static let closedTopRadius: CGFloat = 8
    static let closedBottomRadius: CGFloat = 12
    static let openTopRadius: CGFloat = 16
    /// Deliberately generous — the expanded panel should read as strongly
    /// rounded at the bottom.
    static let openBottomRadius: CGFloat = 65

    /// Horizontal padding the flare consumes on each side. A shape drawn in
    /// a rect of width `w` has a visible body of `w - 2 * topRadius`, so
    /// callers add this to a desired body width to get the frame width.
    static func flareAllowance(topRadius: CGFloat) -> CGFloat { topRadius * 2 }

    /// Black padding between the notch shape's edge and the video/image
    /// content inside it — edit these four to adjust how much breathing
    /// room the media has on each side. Used in `NotchOverlayView`.
    static let contentPaddingTop: CGFloat = 26
    static let contentPaddingLeading: CGFloat = 36
    static let contentPaddingTrailing: CGFloat = 36
    static let contentPaddingBottom: CGFloat = 34
    /// Extra margin baked into the window so SwiftUI's `.shadow()` isn't
    /// clipped by the window bounds (the window itself has `hasShadow =
    /// false` — the shadow is drawn in-content, same trick Boring Notch uses).
    static let shadowPadding: CGFloat = 24

    /// Cosmetic size bump applied on hover in NotchOverlayView — included
    /// here so the fixed window has margin for it at the largest content
    /// size instead of clipping.
    static let hoverBump: CGFloat = 6

    /// The window is created once at this size and never resized — only
    /// `NotchOverlayView`'s content animates inside it (see
    /// NotchWindow.swift). Sized to the largest footprint either scan mode
    /// or any onboarding step will ever ask for, so nothing clips.
    static var windowSize: CGSize {
        let contentWidth = max(openSize.width, OnboardingMetrics.maxPanelWidth)
        let contentHeight = max(openSize.height, OnboardingMetrics.maxPanelHeight)
        return CGSize(
            width: contentWidth + shadowPadding * 2 + hoverBump,
            height: contentHeight + shadowPadding + hoverBump
        )
    }

    /// Synthetic fallback for displays with no physical notch (external
    /// monitors, older MacBooks) — a consistent visual home for the overlay
    /// everywhere, centered at the top edge.
    private static let syntheticClosedSize = CGSize(width: 200, height: 32)

    static func forMainScreen() -> NotchGeometry {
        guard let screen = NSScreen.main else {
            return NotchGeometry(closedSize: syntheticClosedSize, isPhysicalNotch: false)
        }
        return forScreen(screen)
    }

    static func forScreen(_ screen: NSScreen) -> NotchGeometry {
        guard screen.safeAreaInsets.top > 0 else {
            return NotchGeometry(closedSize: syntheticClosedSize, isPhysicalNotch: false)
        }

        // Width derived from the menu-bar areas flanking the notch — the
        // same technique Boring Notch uses. These are nil/empty on displays
        // without a notch, hence the safeAreaInsets check above rather than
        // relying on these being present.
        let leftPadding = screen.auxiliaryTopLeftArea?.width ?? 0
        let rightPadding = screen.auxiliaryTopRightArea?.width ?? 0
        let width = max(screen.frame.width - leftPadding - rightPadding, syntheticClosedSize.width)
        let height = screen.safeAreaInsets.top

        return NotchGeometry(closedSize: CGSize(width: width, height: height), isPhysicalNotch: true)
    }

    /// Picks the best screen for the overlay: the physical notch if any
    /// connected display has one, else the main screen (which gets the
    /// synthetic fallback).
    static func preferredScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }
}
