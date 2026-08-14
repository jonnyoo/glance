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
    static let openBottomRadius: CGFloat = 60

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
    static let pillClosedSize = CGSize(width: 80, height: 24)

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

    // MARK: - Minimal unlock style — EDIT HERE
    //
    // `UnlockAnimationStyle.minimal` never does the full-panel expansion.
    // Instead the silhouette *widens only*, revealing a lock icon on the
    // left and the unlock video on the right:
    //
    //   [ lock ][ · · · gap · · · ][ video ]
    //
    // In notch style the "gap" is the physical notch cutout itself, which
    // has no display behind it — so the two content regions must live in
    // the black flanks this widening creates on either side of it. In pill
    // style there's no cutout, so the same layout just reads as a lock and
    // a video at opposite ends. One layout, both styles; see
    // MinimalUnlockView.

    /// Black width added on *each* side of the physical notch cutout, which
    /// is what creates the visible flanks the content sits in. Total notch
    /// body width is `geometry.closedSize.width + 2 * this`. Ceiling: the
    /// fixed window is ~434pt wide (see `windowSize(for:)`), and a notch
    /// measures ~200-220pt, so much past 100 will start to clip.
    static let minimalNotchFlankWidth: CGFloat = 44

    /// The pill's minimal footprint. Taller than `pillClosedSize.height` so
    /// the icon and video are legible — the corner radius stays
    /// `height / 2` at both ends, so it remains a true capsule while it
    /// stretches.
    static let minimalPillOpenWidth: CGFloat = 150
    static let minimalPillOpenHeight: CGFloat = 40

    /// Radii for the widened notch. Default to the closed values because
    /// the height doesn't change — these exist only so the widened notch
    /// can be rounded differently from the resting one if wanted.
    static let minimalNotchTopRadius: CGFloat = closedTopRadius
    static let minimalNotchBottomRadius: CGFloat = closedBottomRadius

    /// Inset from the silhouette's left/right edges to the content. In
    /// notch style the flare occupies `topRadius` of that margin already,
    /// so this is added on top of it.
    static let minimalContentEdgeInset: CGFloat = 4
    /// Point size of the lock glyph.
    static let minimalLockIconSize: CGFloat = 14
    /// Width of each content region — the lock on one end, the video on the
    /// other. The video is square and aspect-fit, so its rendered size is
    /// really `min(this, panelHeight - 2 * minimalMediaVerticalInset)`.
    static let minimalMediaWidth: CGFloat = 34
    /// Breathing room above and below the video. Without it the square
    /// aspect-fits to the *full* panel height and touches both edges, which
    /// reads as cramped — the panel is only as tall as the notch here.
    static let minimalMediaVerticalInset: CGFloat = 3

    /// Delay between the unlock landing and the lock glyph flipping open,
    /// so it can be nudged to land with the video's own resolve beat
    /// instead of firing on the same frame.
    static let minimalLockUnlockDelay: Double = 0
    /// Duration of the lock → unlock symbol transition. A raw number rather
    /// than an `Animation`, matching the springs above — this file stays
    /// SwiftUI-free and the view builds the curve.
    static let minimalLockAnimationDuration: Double = 0.4

    // MARK: - Scan "breathing" pulse — EDIT HERE
    //
    // While `.scanning` (the camera actively looking for a face), the whole
    // unlock content slowly ping-pongs between full size/opacity and
    // `scanPulseScale`/`scanPulseOpacity`, so the panel reads as *searching*
    // rather than frozen. The moment the scan resolves — success or failure,
    // either way — the pulse stops and returns to full, animating from
    // wherever it happens to be at that instant rather than snapping. Shared
    // by both styles. See `NotchOverlayView.startScanPulse()`.

    /// Scale at the dimmed end of the ping-pong. 1.0 disables the size part.
    static let scanPulseScale: CGFloat = 0.97
    /// Opacity at the dimmed end. 1.0 disables the fade part.
    static let scanPulseOpacity: Double = 0.65
    /// One half-cycle — full → dimmed, or dimmed → full.
    static let scanPulseHalfCycleDuration: Double = 0.4
    /// Pause at each end of the ping-pong before reversing. 0 makes it a
    /// continuous breathe with no rest at the extremes.
    static let scanPulseHoldDuration: Double = 0.05
    /// How long the return-to-full takes when the scan resolves mid-pulse.
    /// Deliberately quicker than a half-cycle so the content is back at full
    /// while the success/failure animation is still early in its playback.
    static let scanPulseSettleDuration: Double = 0.2

    /// Extra wait, once `.scanning` begins, before the first pulse cycle
    /// starts — so the content only starts breathing once the panel has
    /// actually finished expanding, not while it's still mid-grow. In pill
    /// style this is added on top of `pillEnterExpansionDelay` (the
    /// expansion itself doesn't even *start* until that elapses); in notch
    /// style there's no such delay, so this is the only wait. There's no
    /// exact "expansion finished" signal to hook (springs don't have a hard
    /// end time), so this is a hand-tuned approximation — bump it up if the
    /// pulse still visibly starts before the panel looks settled.
    static let scanPulseStartDelay: Double = 0.6

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
            let contentHeight = max(notchOpenSize.height, OnboardingMetrics.maxPanelHeight(for: .notch))
            return CGSize(
                width: contentWidth + notchShadowPadding * 2 + hoverBump,
                height: contentHeight + notchShadowPadding + hoverBump
            )
        case .pill:
            let contentWidth = max(pillOpenSize.width, OnboardingMetrics.maxPanelWidth)
            let contentHeight = max(pillOpenSize.height, OnboardingMetrics.maxPanelHeight(for: .pill))
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
