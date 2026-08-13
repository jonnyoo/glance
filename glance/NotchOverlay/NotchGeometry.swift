//
//  NotchGeometry.swift
//  glance
//
//  Pure geometry — no AppKit window knowledge. Computes where the panel sits
//  on a given screen (on the physical notch, or as a detached pill where
//  there isn't one) and how big the overlay window should be, so
//  NotchWindowController just asks "where" and "how big" without knowing how
//  those numbers were derived.
//

import AppKit
import CoreGraphics

struct NotchGeometry {
    /// Size of the closed (collapsed) silhouette, in the screen's own point
    /// space — the physical notch's own dimensions, or `pillClosedSize`.
    let closedSize: CGSize
    /// True if this screen has a real physical notch (vs. the pill fallback
    /// drawn for external/non-notched displays).
    let isPhysicalNotch: Bool

    /// Which silhouette this screen's panel wears. Screens with real hardware
    /// to sit on get the notch; everything else gets the detached pill.
    var style: NotchPanelStyle { isPhysicalNotch ? .notch : .pill }

    /// Fixed footprint the scan-mode overlay content (armed lock-screen
    /// flow, Face Lab previews) animates within when expanded. Sized for
    /// the square (432x432) scan animation plus breathing room — onboarding
    /// does not use this; see OnboardingMetrics for its per-step sizes.
    static let openSize = CGSize(width: 220, height: 200)

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
    /// Zero in pill style — that shape has no flare, its body *is* the rect.
    static func flareAllowance(topRadius: CGFloat, style: NotchPanelStyle) -> CGFloat {
        style == .notch ? topRadius * 2 : 0
    }

    // MARK: - Pill style (non-notched displays) — EDIT HERE
    //
    // The dynamic-island fallback. Collapsed it's a capsule; expanded it's a
    // floating rounded rectangle at the same footprints the notch uses (scan
    // `openSize`, or whatever step onboarding is on).

    /// Resting/entering pill footprint. Deliberately narrower than every
    /// expanded footprint (the smallest is scan mode's 220pt) so the growth
    /// is visible rather than a barely-perceptible nudge.
    static let pillClosedSize = CGSize(width: 150, height: 32)

    /// How far below the top of the screen the pill and the expanded panel
    /// sit — the whole point of the pill is that it's *detached* from the
    /// edge, so this should never be zero.
    static let pillTopGap: CGFloat = 6

    /// Corner radius of the expanded rounded rectangle. Uniform on all four
    /// corners, unlike the notch (whose heavy bottom radius exists to
    /// balance the flare at the top).
    static let pillOpenCornerRadius: CGFloat = 32

    /// Blur applied to the whole panel — pill body included — while it's
    /// off-screen, resolving to zero as it slides into place.
    static let pillEnterBlur: CGFloat = 12

    /// Extra distance past the top of the screen the pill parks at while
    /// hidden. Comfortably more than `pillEnterBlur` on purpose: a Gaussian
    /// blur spreads well past its nominal radius, and without the margin the
    /// parked pill smears a faint dark band across the top of the screen.
    static let pillOffscreenSlack: CGFloat = 28

    /// Scan-mode top padding in pill style. Larger than the notch's, which
    /// is tuned tight because the camera housing already eats that space.
    static let pillContentPaddingTop: CGFloat = 30

    /// Black padding between the notch shape's edge and the video/image
    /// content inside it — edit these four to adjust how much breathing
    /// room the media has on each side. Used in `NotchOverlayView`.
    static let contentPaddingTop: CGFloat = 26
    static let contentPaddingLeading: CGFloat = 40
    static let contentPaddingTrailing: CGFloat = 40
    static let contentPaddingBottom: CGFloat = 30
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
            // `pillTopGap` because the pill style pushes its whole panel
            // down by that much — without it the extra travel eats into the
            // shadow margin at the bottom.
            height: contentHeight + shadowPadding + hoverBump + pillTopGap
        )
    }

    /// Floor for a *physical* notch's measured width — the auxiliary-area
    /// arithmetic below can come up implausibly small on odd display
    /// configurations. Unrelated to `pillClosedSize`, which is a design
    /// choice rather than a guard rail.
    private static let minimumNotchWidth: CGFloat = 200

    static func forMainScreen() -> NotchGeometry {
        guard let screen = NSScreen.main else {
            return NotchGeometry(closedSize: pillClosedSize, isPhysicalNotch: false)
        }
        return forScreen(screen)
    }

    static func forScreen(_ screen: NSScreen) -> NotchGeometry {
        guard screen.safeAreaInsets.top > 0 else {
            return NotchGeometry(closedSize: pillClosedSize, isPhysicalNotch: false)
        }

        // Width derived from the menu-bar areas flanking the notch — the
        // same technique Boring Notch uses. These are nil/empty on displays
        // without a notch, hence the safeAreaInsets check above rather than
        // relying on these being present.
        let leftPadding = screen.auxiliaryTopLeftArea?.width ?? 0
        let rightPadding = screen.auxiliaryTopRightArea?.width ?? 0
        let width = max(screen.frame.width - leftPadding - rightPadding, minimumNotchWidth)
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
