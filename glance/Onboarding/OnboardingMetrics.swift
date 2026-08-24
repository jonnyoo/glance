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
    // (the camera step), which keeps its own independent width in
    // `enrollPanelWidth` below — widths are NOT split per style (only
    // heights are). Height, though, is fully independent per step *and* per
    // style: 12 numbers total, edit any one without affecting any other —
    // the panel animates to the new height the moment that step becomes
    // active on whichever style is currently showing.

    /// Width used by every step except `.enroll`. Increase/decrease this
    /// one number to make the whole flow (minus the camera step) wider or
    /// narrower, in both styles.
    static let panelWidth: CGFloat = 380

    /// The camera/enrollment step's width — deliberately independent of
    /// `panelWidth` (kept at its original, pre-redesign-tweak footprint).
    static let enrollPanelWidth: CGFloat = 320

    static let notchIntroHeight: CGFloat = 175
    static let pillIntroHeight: CGFloat = 175
    static let notchPermissionsHeight: CGFloat = 245
    static let pillPermissionsHeight: CGFloat = 245
    static let notchPreSetupHeight: CGFloat = 220
    static let pillPreSetupHeight: CGFloat = 220
    static let notchEnrollHeight: CGFloat = 344
    static let pillEnrollHeight: CGFloat = 350
    static let notchNameHeight: CGFloat = 230
    static let pillNameHeight: CGFloat = 230
    static let notchPasswordHeight: CGFloat = 260
    static let pillPasswordHeight: CGFloat = 260
    static let notchCompleteHeight: CGFloat = 95
    static let pillCompleteHeight: CGFloat = 95

    static func panelHeight(for step: OnboardingStep, style: NotchPanelStyle) -> CGFloat {
        switch (step, style) {
        case (.intro, .notch): return notchIntroHeight
        case (.intro, .pill): return pillIntroHeight
        case (.permissions, .notch): return notchPermissionsHeight
        case (.permissions, .pill): return pillPermissionsHeight
        case (.preSetup, .notch): return notchPreSetupHeight
        case (.preSetup, .pill): return pillPreSetupHeight
        case (.enroll, .notch): return notchEnrollHeight
        case (.enroll, .pill): return pillEnrollHeight
        case (.name, .notch): return notchNameHeight
        case (.name, .pill): return pillNameHeight
        case (.password, .notch): return notchPasswordHeight
        case (.password, .pill): return pillPasswordHeight
        case (.complete, .notch): return notchCompleteHeight
        case (.complete, .pill): return pillCompleteHeight
        }
    }

    static func panelSize(for step: OnboardingStep, style: NotchPanelStyle) -> CGSize {
        let width = step == .enroll ? enrollPanelWidth : panelWidth
        return CGSize(width: width, height: panelHeight(for: step, style: style))
    }

    static func panelBottomRadius(for step: OnboardingStep) -> CGFloat {
        switch step {
        case .enroll: return 51.5
        default: return 55
        }
    }

    /// The envelope the fixed notch window itself must be sized to fit —
    /// see `NotchGeometry.windowSize(for:)`, which combines this with the
    /// pre-existing scan-mode footprint. Width isn't split per style, so
    /// stays a single value; height is, so it's a per-style max.
    static let maxPanelWidth: CGFloat = max(panelWidth, enrollPanelWidth)

    static func maxPanelHeight(for style: NotchPanelStyle) -> CGFloat {
        switch style {
        case .notch:
            return [
                notchIntroHeight, notchPermissionsHeight, notchPreSetupHeight,
                notchEnrollHeight, notchNameHeight, notchPasswordHeight, notchCompleteHeight,
            ].max() ?? notchEnrollHeight
        case .pill:
            return [
                pillIntroHeight, pillPermissionsHeight, pillPreSetupHeight,
                pillEnrollHeight, pillNameHeight, pillPasswordHeight, pillCompleteHeight,
            ].max() ?? pillEnrollHeight
        }
    }

    // MARK: - Content insets, per style — EDIT HERE
    //
    // Independent top/left/right/bottom insets for onboarding step content
    // — notch and pill can be tuned entirely separately, and neither
    // touches the other. This does NOT apply to the scan/unlock content
    // (see `NotchGeometry.notchContentPadding*`/`pillContentPadding*` for
    // that instead) — onboarding only.

    /// Deliberately generous in notch style: the physical notch's camera
    /// housing overlaps the very top of the panel, so title/text content
    /// needs real clearance below it or it reads as clipped.
    static let titleTopInset: CGFloat = 50
    /// Pill style has no housing to clear — the panel floats free of the
    /// screen edge — so the same inset just leaves content sitting low.
    static let pillTitleTopInset: CGFloat = 32

    static let notchContentLeadingInset: CGFloat = 28
    static let notchContentTrailingInset: CGFloat = 28
    static let notchContentBottomInset: CGFloat = 40

    static let pillContentLeadingInset: CGFloat = 30
    static let pillContentTrailingInset: CGFloat = 30
    static let pillContentBottomInset: CGFloat = 36

    static func titleTopInset(for style: NotchPanelStyle) -> CGFloat {
        style == .pill ? pillTitleTopInset : titleTopInset
    }

    static func contentLeadingInset(for style: NotchPanelStyle) -> CGFloat {
        style == .pill ? pillContentLeadingInset : notchContentLeadingInset
    }

    static func contentTrailingInset(for style: NotchPanelStyle) -> CGFloat {
        style == .pill ? pillContentTrailingInset : notchContentTrailingInset
    }

    static func contentBottomInset(for style: NotchPanelStyle) -> CGFloat {
        style == .pill ? pillContentBottomInset : notchContentBottomInset
    }

    // MARK: - Shared control geometry

    static let controlHorizontalPadding: CGFloat = 24

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
    static let tickRingOuterDiameter: CGFloat = 200

    /// 10 ticks per 45deg sector x 8 sectors = 80 ticks tiling the ring.
    static let tickCount = 80
    static let ticksPerSector = 10
    static let tickLengthUnlit: CGFloat = 12
    static let tickLengthLit: CGFloat = 20
    static let tickWidth: CGFloat = 2.4
    /// Stroke width of the solid ring the ticks merge into on completion.
    /// Deliberately its own constant rather than reusing `tickLengthLit`
    /// (the original approach) — that coupled the ring's thickness to the
    /// individual tick length, so thinning the ring meant either shrinking
    /// every lit tick too or fighting the frame math. `EnrollmentRingView`
    /// keeps the ring's outer edge exactly where the lit ticks' outer tips
    /// were (`diameter/2 + tickLengthLit`) regardless of this value, so it
    /// can be tuned on its own.
    static let completionRingWidth: CGFloat = 14
    /// Width ticks expand to when they merge into the completion ring.
    static var tickWidthComplete: CGFloat {
        2 * .pi * (tickRingOuterDiameter / 2) / CGFloat(tickCount) * 1.2
    }
    /// Per-tick stagger so a captured sector fills as a sweep rather than
    /// snapping all ten ticks at once.
    static let tickStagger: Double = 0.008

    /// Diameter reserved for the camera + ring, including room for lit
    /// ticks that grow outward from `tickRingOuterDiameter`.
    static var enrollCameraClusterDiameter: CGFloat {
        tickRingOuterDiameter + tickLengthLit * 2
    }

    // MARK: - Enrollment camera-complete sequence timings (seconds)

    static let guideOverlayFadeOut: Double = 0.35
    static let previewFadeOut: Double = 0.4
    static let checkmarkDelay: Double = 0.2
    static let checkmarkDrawDuration: Double = 0.28
    /// How long the checkmark holds after the nine poses before the panel
    /// moves on to the naming step.
    static let cameraCompleteToNameDelay: Double = 3.0
    static let completeScreenDismissDelay: Double = 3.0

    // MARK: - In-panel enrollment chrome

    static let enrollInstructionBottomPadding: CGFloat = 30
    static let enrollInstructionHorizontalPadding: CGFloat = 20
    static let enrollCameraTopPaddingNotch: CGFloat = 40
    static let enrollCameraTopPaddingPill: CGFloat = 30

    static let enrollCloseButtonSize: CGFloat = 28
    /// Inset from the panel's top and trailing edges — independent of
    /// enroll content padding so the control sits on the window chrome,
    /// not the camera cluster.
    static let enrollCloseButtonEdgePadding: CGFloat = 18

    static let enrollTooFarChevronSize: CGFloat = 32
    static let enrollInstructionFadeIn: Double = 0.3
    static let enrollInstructionFadeOut: Double = 0.35

    // MARK: - Enrollment direction sweep

    /// Pause between the last streak of a cycle finishing and the next
    /// cycle starting, so the motion reads as a repeated cue rather than
    /// a continuous wash of light.
    static let sweepLoopGap: Double = 1
    /// Caps the stacked streak opacities so the camera preview stays
    /// visually dominant even when several ribbons overlap.
    static let sweepMasterOpacity: Double = 0.6
    static let sweepFadeIn: Double = 0.5
    static let sweepFadeOut: Double = 0.35
    static let sweepDirectionCrossfade: Double = 0.25
    /// Beat of stillness after a pose change before the next sweep plays.
    static let sweepPoseDelay: Double = 0.36
}

extension View {
    /// All four content-edge insets for a step view — leading, trailing,
    /// top, and bottom — sized to whichever silhouette the panel is
    /// currently wearing (see `NotchPanelStyle`). Reads the style from the
    /// environment rather than taking a parameter so every step view stays a
    /// plain `(controller) -> View`.
    func onboardingContentPadding() -> some View {
        modifier(OnboardingContentPadding())
    }

    /// Just the left/right insets — for steps (like `.complete`) that use
    /// their own top/bottom spacing instead of the standard title/content
    /// insets.
    func onboardingContentHorizontalPadding() -> some View {
        modifier(OnboardingContentHorizontalPadding())
    }
}

private struct OnboardingContentHorizontalPadding: ViewModifier {
    @Environment(\.notchPanelStyle) private var style

    func body(content: Content) -> some View {
        content
            .padding(.leading, OnboardingMetrics.contentLeadingInset(for: style))
            .padding(.trailing, OnboardingMetrics.contentTrailingInset(for: style))
    }
}

private struct OnboardingContentPadding: ViewModifier {
    @Environment(\.notchPanelStyle) private var style

    func body(content: Content) -> some View {
        content
            .onboardingContentHorizontalPadding()
            .padding(.top, OnboardingMetrics.titleTopInset(for: style))
            .padding(.bottom, OnboardingMetrics.contentBottomInset(for: style))
    }
}
