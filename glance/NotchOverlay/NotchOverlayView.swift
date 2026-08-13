//
//  NotchOverlayView.swift
//  glance
//
//  SwiftUI root hosted inside the fixed-size NotchWindow. Only this view's
//  *content* moves and resizes — the window itself never changes size or
//  position. Asymmetric springs (slight overshoot opening, critically damped
//  closing) match the feel established while studying Boring Notch's
//  animation.
//
//  Two silhouettes, picked per screen (see NotchPanelStyle):
//
//  - `.notch` — the original. Welded to the top edge, collapsing to the
//    physical notch's own dimensions. Never leaves the screen; at rest it is
//    invisible because it's sitting exactly on the hardware.
//  - `.pill` — for displays with no notch to sit on. A detached dynamic
//    island: parked off-screen above the top edge while hidden, sliding down
//    into view as it expands (blurred → sharp), and sliding back up on the
//    way out. On the lock screen it *docks* instead — resting on screen as a
//    capsule between attempts, growing in place rather than sliding.
//
//  Interaction is hover-only (see NotchOverlayController) — hovering both
//  triggers activation (wake/retry) and shows a purely cosmetic size+shadow
//  bump, independent of whether this particular hover did anything.
//

import SwiftUI

struct NotchOverlayView: View {
    let controller: NotchOverlayController

    @State private var isHovering = false

    /// Where the panel currently sits. `.hidden` is pill-only — the notch
    /// silhouette is part of the hardware's outline and never travels.
    private enum Presentation {
        /// Parked off-screen above the top edge, blurred.
        case hidden
        /// At rest on screen at the closed silhouette's size.
        case resting
        /// Grown to the scan or onboarding footprint.
        case expanded
    }

    private var style: NotchPanelStyle {
        controller.geometry.style
    }

    private var isExpanded: Bool {
        switch controller.phase {
        case .closed, .collapsing: return false
        case .scanning, .success, .failure, .onboarding: return true
        }
    }

    private var presentation: Presentation {
        if isExpanded { return .expanded }
        if style == .notch { return .resting }
        return controller.isPillDocked ? .resting : .hidden
    }

    /// While onboarding is active, the panel body tracks whatever step the
    /// hosted OnboardingController is on instead of the fixed scan-mode
    /// `openSize` — this is what makes the panel visibly grow/shrink per
    /// step.
    private var onboardingController: OnboardingController? {
        if case .onboarding(let controller) = controller.content { return controller }
        return nil
    }

    private var openBodySize: CGSize {
        onboardingController?.panelSize ?? NotchGeometry.openSize
    }

    /// The physical notch's measured size, or `NotchGeometry.pillClosedSize`
    /// — `NotchGeometry.forScreen` already picks the right one per screen.
    private var closedBodySize: CGSize {
        controller.geometry.closedSize
    }

    private var topRadius: CGFloat {
        switch (style, presentation) {
        case (.notch, .expanded): return NotchGeometry.openTopRadius
        case (.notch, _): return NotchGeometry.closedTopRadius
        case (.pill, .expanded): return NotchGeometry.pillOpenCornerRadius
        // Half the height is exactly a capsule end.
        case (.pill, _): return closedBodySize.height / 2
        }
    }

    private var bottomRadius: CGFloat {
        switch (style, presentation) {
        case (.notch, .expanded):
            return onboardingController?.panelBottomRadius ?? NotchGeometry.openBottomRadius
        case (.notch, _):
            return NotchGeometry.closedBottomRadius
        // Uniform corners in pill style: onboarding's per-step bottom radius
        // exists to balance the notch's flare, which the pill doesn't have.
        case (.pill, .expanded):
            return NotchGeometry.pillOpenCornerRadius
        case (.pill, _):
            return closedBodySize.height / 2
        }
    }

    /// In notch style the shape's visible body is inset by `topRadius` per
    /// side (the flare lives in that margin), so the frame is widened to
    /// compensate — that way the closed state lands exactly on the physical
    /// notch width instead of coming up short by the flare. The pill has no
    /// flare and so no allowance. The hover bump adds a uniform few points
    /// on top of whatever size the phase already wants.
    private var currentSize: CGSize {
        let body = isExpanded ? openBodySize : closedBodySize
        let bump: CGFloat = isHovering ? NotchGeometry.hoverBump : 0
        return CGSize(
            width: body.width + NotchGeometry.flareAllowance(topRadius: topRadius, style: style) + bump,
            height: body.height + bump
        )
    }

    /// Because the panel is laid out top-aligned inside the fixed window
    /// frame, height always grows downward — so sliding is purely a matter
    /// of where the *top* edge sits.
    private var verticalOffset: CGFloat {
        guard style == .pill else { return 0 }
        switch presentation {
        case .hidden:
            return -(closedBodySize.height + NotchGeometry.pillOffscreenSlack)
        case .resting, .expanded:
            return NotchGeometry.pillTopGap
        }
    }

    /// Blurs the entire panel — black body included — while it's off-screen,
    /// so it resolves into focus as it slides down rather than snapping in.
    /// Never applied to a docked pill: the lock screen's resting state
    /// should read as crisp.
    private var panelBlur: CGFloat {
        style == .pill && presentation == .hidden ? NotchGeometry.pillEnterBlur : 0
    }

    private var scanContentTopPadding: CGFloat {
        style == .pill ? NotchGeometry.pillContentPaddingTop : NotchGeometry.contentPaddingTop
    }

    private var openCloseAnimation: Animation {
        isExpanded
            ? .spring(response: 0.42, dampingFraction: 0.8)
            : .spring(response: 0.45, dampingFraction: 1.0)
    }

    var body: some View {
        ZStack {
            Group {
                if let onboardingController {
                    // Onboarding's step views lay themselves out to exactly
                    // fill `panelSize` — no shared content padding here,
                    // unlike the scan animation below.
                    OnboardingNotchView(controller: onboardingController)
                } else {
                    ScanAnimationView(media: controller.media)
                        .padding(.leading, NotchGeometry.contentPaddingLeading)
                        .padding(.trailing, NotchGeometry.contentPaddingTrailing)
                        .padding(.top, scanContentTopPadding)
                        .padding(.bottom, NotchGeometry.contentPaddingBottom)
                }
            }
            // Content dissolves as the panel shrinks: increasing blur
            // plus a fade, so it melts away rather than being abruptly
            // clipped by the collapsing shape.
            .blur(radius: isExpanded ? 0 : 14)
            .opacity(isExpanded ? 1 : 0)
            .scaleEffect(isExpanded ? 1 : 0.88)
            .environment(\.notchPanelStyle, style)
        }
        .frame(width: currentSize.width, height: currentSize.height)
        .background(Color.black)
        .clipShape(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius, style: style))
        .blur(radius: panelBlur)
        // Shadow only while expanded — with the window staying on-screen
        // continuously in armed mode, a shadow visible at the *closed* size
        // rendered as a faint dim halo sitting around the real notch even
        // after "dismissing." Radius is fixed rather than growing on hover
        // (only darkness changes) since a larger radius needs more
        // window margin than is reserved and was getting clipped.
        .shadow(color: .black.opacity(isExpanded ? (isHovering ? 0.55 : 0.3) : 0), radius: 9)
        // Applied after the shadow so both travel together, and before
        // `.onHover` so the hover region tracks where the panel actually is.
        .offset(y: verticalOffset)
        .animation(.easeOut(duration: 0.18), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                controller.activate()
            }
        }
        .animation(openCloseAnimation, value: isExpanded)
        // Drives the pill's slide in/out independently of expansion — the
        // lock screen docks it while still closed, and undocks it once the
        // attempt is truly over.
        .animation(openCloseAnimation, value: controller.isPillDocked)
        // Drives the per-step resize while onboarding is active — isExpanded
        // alone only fires once, on entering/leaving the expanded state.
        .animation(openCloseAnimation, value: onboardingController?.panelSize)
        .frame(
            width: NotchGeometry.windowSize.width,
            height: NotchGeometry.windowSize.height,
            alignment: .top
        )
    }
}
