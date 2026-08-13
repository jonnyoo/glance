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
    /// flow, Face Lab previews) animates within when expanded, in notch
    /// style. Sized for the square (432x432) scan animation plus breathing
    /// room — onboarding does not use this; see OnboardingMetrics for its
    /// per-step sizes. Pill style has its own `pillOpenSize` below — the two
    /// are independent so editing one never touches the other.
    static let notchOpenSize = CGSize(width: 220, height: 200)

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
    // floating rounded rectangle sized by `pillOpenSize` in scan mode, or
    // whatever step onboarding is on.

    /// Resting/entering pill footprint. Deliberately narrower than every
    /// expanded footprint (the smallest is scan mode's `pillOpenSize`) so
    /// the growth is visible rather than a barely-perceptible nudge.
    static let pillClosedSize = CGSize(width: 90, height: 24)

    /// Scan-mode (armed lock-screen flow, Face Lab previews) footprint in
    /// pill style — the pill's equivalent of `notchOpenSize` above, sized
    /// independently so it can be tuned without touching the notch. Larger
    /// than the notch's by default since the pill has no camera housing
    /// eating into its usable content area.
    static let pillOpenSize = CGSize(width: 180, height: 180)

    /// How far below the top of the screen the pill and the expanded panel
    /// sit — the whole point of the pill is that it's *detached* from the
    /// edge, so this should never be zero.
    static let pillTopGap: CGFloat = 3

    /// Corner radius of the expanded rounded rectangle. Uniform on all four
    /// corners, unlike the notch (whose heavy bottom radius exists to
    /// balance the flare at the top) — matches `openBottomRadius` so the two
    /// styles' expanded panels read as equally rounded.
    static let pillOpenCornerRadius: CGFloat = 48

    /// Blur applied to the whole panel — pill body included — while it's
    /// off-screen, resolving to zero as it slides into place.
    static let pillEnterBlur: CGFloat = 0

    /// Extra distance past the top of the screen the pill parks at while
    /// hidden. Comfortably more than `pillEnterBlur` on purpose: a Gaussian
    /// blur spreads well past its nominal radius, and without the margin the
    /// parked pill smears a faint dark band across the top of the screen.
    static let pillOffscreenSlack: CGFloat = 20

    /// Black padding between the pill's edge and the scan-mode video/image
    /// content inside it — the pill's equivalent of `notchContentPadding*`
    /// above, independent so it can be tuned without touching the notch.
    /// Top is larger than the notch's by default since the notch's is tuned
    /// tight to clear the camera housing, which the pill doesn't have.
    static let pillContentPaddingTop: CGFloat = 32
    static let pillContentPaddingLeading: CGFloat = 32
    static let pillContentPaddingTrailing: CGFloat = 32
    static let pillContentPaddingBottom: CGFloat = 32

    // MARK: - Panel open/close springs — EDIT HERE
    //
    // Shared by both styles for the size/radius motion (the pill's slide has
    // its own timing below). Opening overshoots slightly; closing is
    // critically damped — the feel established while studying Boring Notch's
    // animation.
    static let openSpringResponse: Double = 0.45
    static let openSpringDamping: Double = 0.7
    static let closeSpringResponse: Double = 0.45
    static let closeSpringDamping: Double = 1.0

    // MARK: - Pill enter/exit choreography — EDIT HERE
    //
    // Style `.pill` only — the physical notch is drawn on hardware that's
    // already there, so it never slides. The pill's slide (vertical
    // position) and its expansion (size + corner radius) deliberately run on
    // two independent timelines rather than moving in lockstep:
    //
    //   Enter: slide leads — starts immediately, finishes first.
    //          Expansion trails — starts after `pillEnterExpansionDelay`,
    //          finishes last. The pill drops into position, then grows.
    //   Exit:  shrink leads — starts immediately, finishes first (it reuses
    //          the close spring above, undelayed).
    //          Slide trails — starts after `pillExitSlideDelay`, finishes
    //          last. The pill shrinks back down, then slides away.

    /// Duration of the slide motion, both directions. Ease-out (fast start,
    /// gentle settle) rather than a spring — this is a straight-line
    /// off-screen/on-screen move, not a bouncy resize.
    static let pillSlideDuration: Double = 0.25
    /// Delay before the expansion starts on enter, after the slide is
    /// already underway. Larger than this plus the slide duration and the
    /// expansion would start before the slide even finishes.
    static let pillEnterExpansionDelay: Double = 0.16
    /// Delay before the slide starts on exit, after the shrink is already
    /// underway.
    static let pillExitSlideDelay: Double = 0.18

    /// Black padding between the notch shape's edge and the scan-mode
    /// video/image content inside it, in notch style — edit these four to
    /// adjust how much breathing room the media has on each side. Used in
    /// `NotchOverlayView`. Pill style has its own independent set below.
    static let notchContentPaddingTop: CGFloat = 26
    static let notchContentPaddingLeading: CGFloat = 40
    static let notchContentPaddingTrailing: CGFloat = 40
    static let notchContentPaddingBottom: CGFloat = 30

    /// Cosmetic size bump applied on hover in NotchOverlayView — shared by
    /// both styles. Included here so the fixed window has margin for it at
    /// the largest content size instead of clipping.
    static let hoverBump: CGFloat = 6

    // MARK: - Window size, per style — EDIT HERE
    //
    // The window is created once (at whichever style is active for the
    // current display at creation time) and never resized afterward — only
    // `NotchOverlayView`'s content animates inside it (see NotchWindow.swift).
    // Each style is floored to its OWN scan-mode footprint (`notchOpenSize`
    // or `pillOpenSize`) and gets its own shadow margin, so pill and notch
    // can be tuned entirely independently — changing one never changes the
    // other's window size.

    /// Extra margin baked into the notch window so SwiftUI's `.shadow()`
    /// isn't clipped by the window bounds (the window itself has
    /// `hasShadow = false` — the shadow is drawn in-content, same trick
    /// Boring Notch uses).
    static let notchShadowPadding: CGFloat = 24
    /// Same idea for the pill window. Separate from the notch's so the two
    /// can be sized independently.
    static let pillShadowPadding: CGFloat = 24

    static func windowSize(for style: NotchPanelStyle) -> CGSize {
        switch style {
        case .notch:
            let contentWidth = max(notchOpenSize.width, OnboardingMetrics.maxPanelWidth)
            let contentHeight = max(notchOpenSize.height, OnboardingMetrics.maxPanelHeight)
            return CGSize(
                width: contentWidth + notchShadowPadding * 2 + hoverBump,
                height: contentHeight + notchShadowPadding + hoverBump
            )
        case .pill:
            let contentWidth = max(pillOpenSize.width, OnboardingMetrics.maxPanelWidth)
            let contentHeight = max(pillOpenSize.height, OnboardingMetrics.maxPanelHeight)
            return CGSize(
                width: contentWidth + pillShadowPadding * 2 + hoverBump,
                // `pillTopGap` because the pill sits detached from the top
                // edge, pushing its whole panel down by that much — without
                // it the extra travel eats into the shadow margin at the
                // bottom.
                height: contentHeight + pillShadowPadding + hoverBump + pillTopGap
            )
        }
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
