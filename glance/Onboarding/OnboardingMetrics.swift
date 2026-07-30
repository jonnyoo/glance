//
//  OnboardingMetrics.swift
//  glance
//
//  Every layout number the redesign needs. Centralized so panel-fit tuning
//  happens in one place instead of being scattered across the step views.
//

import SwiftUI

enum OnboardingMetrics {
    /// Shared spring for both the notch panel's resize (NotchOverlayView)
    /// and the step content's scroll+blur transition (OnboardingNotchView)
    /// — driven explicitly via `withAnimation` at every step-changing call
    /// site in OnboardingController, so the two always move together
    /// regardless of how the state mutation was triggered (a button tap vs.
    /// an async completion handler).
    static let stepAnimation = Animation.spring(response: 0.42, dampingFraction: 0.8)

    // MARK: - Panel size — EDIT HERE
    //
    // `panelWidth` is shared by every onboarding step *except* `.enroll`
    // (the camera step), which keeps its own independent size in
    // `enrollPanelSize` below, unchanged by anything here. Every other step
    // gets its own height, so panels can be short (Permissions) or tall
    // (Password) without affecting one another — the notch panel animates
    // between them automatically whenever `OnboardingController.step`
    // changes.

    /// Width used by every step except `.enroll`. Increase/decrease this
    /// one number to make the whole flow (minus the camera step) wider or
    /// narrower.
    static let panelWidth: CGFloat = 380

    /// Height of each individual step. Edit any one of these independently
    /// — the panel will animate to the new height the moment that step
    /// becomes active.
    static let introHeight: CGFloat = 175
    static let permissionsHeight: CGFloat = 245
    static let preSetupHeight: CGFloat = 220
    static let passwordHeight: CGFloat = 260
    static let completeHeight: CGFloat = 95

    /// The camera/enrollment step's panel — deliberately independent of
    /// `panelWidth`/the per-step heights above (kept at its original,
    /// pre-redesign-tweak footprint). Edit this pair directly if the
    /// camera step ever needs to change size on its own.
    static let enrollPanelSize = CGSize(width: 315, height: 310)

    static func panelSize(for step: OnboardingStep) -> CGSize {
        if step == .enroll { return enrollPanelSize }
        return CGSize(width: panelWidth, height: panelHeight(for: step))
    }

    static func panelHeight(for step: OnboardingStep) -> CGFloat {
        switch step {
        case .intro: return introHeight
        case .permissions: return permissionsHeight
        case .preSetup: return preSetupHeight
        case .enroll: return enrollPanelSize.height
        case .password: return passwordHeight
        case .complete: return completeHeight
        }
    }

    static func panelBottomRadius(for step: OnboardingStep) -> CGFloat {
        switch step {
        case .enroll: return 51.5
        default: return 55
        }
    }

    /// The envelope the fixed notch window itself must be sized to fit —
    /// see `NotchGeometry.windowSize`, which combines this with the
    /// pre-existing scan-mode footprint.
    static let maxPanelWidth: CGFloat = max(panelWidth, enrollPanelSize.width)
    static let maxPanelHeight: CGFloat = [
        introHeight, permissionsHeight, preSetupHeight, enrollPanelSize.height, passwordHeight, completeHeight,
    ].max() ?? enrollPanelSize.height

    // MARK: - Shared control geometry

    static let contentHorizontalPadding: CGFloat = 28
    static let controlHorizontalPadding: CGFloat = 24
    /// Deliberately generous: the physical notch's camera housing overlaps
    /// the very top of the panel, so title/text content needs real
    /// clearance below it or it reads as clipped.
    static let titleTopInset: CGFloat = 50
    static let contentBottomInset: CGFloat = 40

    static let pillButtonHeight: CGFloat = 38
    static let pillButtonRadius: CGFloat = 17
    static let primaryButtonWidth: CGFloat = 160

    static let permissionRowHeight: CGFloat = 44
    static let grantButtonSize = CGSize(width: 60, height: 26)
    static let statusDotSize: CGFloat = 16

    // MARK: - Camera / tick ring
    //
    // The preview is kept smaller than the ring so the tick marks stay
    // visible around its edge instead of being covered by the video.

    static let cameraCircleDiameter: CGFloat = 185
    static let tickRingOuterDiameter: CGFloat = 235

    /// 10 ticks per 45deg sector x 8 sectors = 80 ticks tiling the ring.
    static let tickCount = 80
    static let ticksPerSector = 10
    static let tickLengthUnlit: CGFloat = 12
    static let tickLengthLit: CGFloat = 18
    static let tickWidth: CGFloat = 2.2
    /// Per-tick stagger so a captured sector fills as a sweep rather than
    /// snapping all ten ticks at once.
    static let tickStagger: Double = 0.008

    // MARK: - Enrollment camera-complete sequence timings (seconds)

    static let guideOverlayFadeOut: Double = 0.35
    static let previewFadeOut: Double = 0.4
    static let checkmarkDelay: Double = 0.2
    static let checkmarkDrawDuration: Double = 0.5
    static let cameraCompleteToPasswordDelay: Double = 3.0
    static let completeScreenDismissDelay: Double = 3.0

    // MARK: - Full-screen guide overlay

    static let guideDimOpacity: Double = 0.72
    static let guideArrowSize: CGFloat = 72
    static let guideTextSpacing: CGFloat = 24
    static let guideFadeIn: Double = 0.3
    static let guideFadeOut: Double = 0.35
}
