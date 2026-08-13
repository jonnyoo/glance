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
//  Enter/exit choreography (pill style only — see `scheduleChoreography()`):
//  the slide (position/blur) and the expansion (size/radius/shadow) run on
//  two independent timelines, one leading and one trailing, rather than
//  moving in lockstep. This is NOT done with two overlapping
//  `.animation(_:value:)` modifiers sharing one state change — tried that,
//  and it doesn't stagger reliably: when two `.animation(value:)` calls both
//  fire for the same underlying transaction, SwiftUI doesn't cleanly split
//  "which properties belong to which call," and the whole panel ends up
//  waiting out the longer of the two (a large `pillEnterExpansionDelay` held
//  the *entire* pill offscreen, slide included, instead of just delaying the
//  size/radius change). Instead, `visualIsExpanded`/`visualIsPositioned` are
//  separate `@State` mirrors of the controller's target state, and
//  `scheduleChoreography()` mutates them at genuinely different real
//  moments — the leading one immediately, the trailing one after an actual
//  `Task.sleep` — each inside its own explicit `withAnimation`. Two
//  mutations that happen at different times animate independently with no
//  ambiguity; no `.animation(_:value:)` modifier is needed for either.
//
//  Interaction is hover-only (see NotchOverlayController) — hovering both
//  triggers activation (wake/retry) and shows a purely cosmetic size+shadow
//  bump, independent of whether this particular hover did anything.
//

import SwiftUI

struct NotchOverlayView: View {
    let controller: NotchOverlayController

    @State private var isHovering = false

    /// Visual mirrors of the controller's target state — see the file
    /// header for why these are separate `@State` rather than computed
    /// directly from `controller.phase`/`controller.isPillDocked`.
    @State private var visualIsExpanded = false
    @State private var visualIsPositioned = false
    /// The in-flight trailing half of an enter/exit choreography, if any —
    /// cancelled and replaced whenever a new target supersedes it.
    @State private var choreographyTask: Task<Void, Never>?

    private var style: NotchPanelStyle {
        controller.geometry.style
    }

    /// Where the controller currently wants the panel: expanded (scan /
    /// onboarding) or not. `scheduleChoreography()` compares this against
    /// `visualIsExpanded` to decide what needs to move.
    private var targetIsExpanded: Bool {
        switch controller.phase {
        case .closed, .collapsing: return false
        case .scanning, .success, .failure, .onboarding: return true
        }
    }

    /// Where the controller currently wants the panel: on-screen (resting or
    /// expanded) or parked off-screen. Notch style is always on-screen — the
    /// physical notch never travels, it's drawn on hardware that's already
    /// there. Expanded always implies positioned, regardless of the docked
    /// flag, so a mid-success `disarm()` (which undocks) doesn't yank the
    /// panel away while it's still showing the success animation.
    private var targetIsPositioned: Bool {
        if targetIsExpanded { return true }
        if style == .notch { return true }
        return controller.isPillDocked
    }

    /// While onboarding is active, the panel body tracks whatever step the
    /// hosted OnboardingController is on instead of the fixed scan-mode
    /// footprint (`NotchGeometry.notchOpenSize`/`pillOpenSize`) — this is
    /// what makes the panel visibly grow/shrink per step.
    private var onboardingController: OnboardingController? {
        if case .onboarding(let controller) = controller.content { return controller }
        return nil
    }

    /// Scan-mode footprint for the active style — independently editable via
    /// `NotchGeometry.notchOpenSize`/`pillOpenSize`.
    private var scanOpenSize: CGSize {
        style == .notch ? NotchGeometry.notchOpenSize : NotchGeometry.pillOpenSize
    }

    private var openBodySize: CGSize {
        onboardingController?.panelSize ?? scanOpenSize
    }

    /// The physical notch's measured size, or `NotchGeometry.pillClosedSize`
    /// — `NotchGeometry.forScreen` already picks the right one per screen.
    private var closedBodySize: CGSize {
        controller.geometry.closedSize
    }

    private var topRadius: CGFloat {
        if visualIsExpanded {
            return style == .notch ? NotchGeometry.openTopRadius : NotchGeometry.pillOpenCornerRadius
        }
        // Half the height is exactly a capsule end, in pill style.
        return style == .notch ? NotchGeometry.closedTopRadius : closedBodySize.height / 2
    }

    private var bottomRadius: CGFloat {
        if visualIsExpanded {
            guard style == .notch else {
                // Uniform corners in pill style: onboarding's per-step
                // bottom radius exists to balance the notch's flare, which
                // the pill doesn't have.
                return NotchGeometry.pillOpenCornerRadius
            }
            return onboardingController?.panelBottomRadius ?? NotchGeometry.openBottomRadius
        }
        return style == .notch ? NotchGeometry.closedBottomRadius : closedBodySize.height / 2
    }

    /// In notch style the shape's visible body is inset by `topRadius` per
    /// side (the flare lives in that margin), so the frame is widened to
    /// compensate — that way the closed state lands exactly on the physical
    /// notch width instead of coming up short by the flare. The pill has no
    /// flare and so no allowance. The hover bump adds a uniform few points
    /// on top of whatever size the phase already wants.
    private var currentSize: CGSize {
        let body = visualIsExpanded ? openBodySize : closedBodySize
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
        guard visualIsPositioned else {
            return -(closedBodySize.height + NotchGeometry.pillOffscreenSlack)
        }
        return NotchGeometry.pillTopGap
    }

    /// Blurs the entire panel — black body included — while it's off-screen,
    /// so it resolves into focus as it slides down rather than snapping in.
    /// Never applied to a docked pill: the lock screen's resting state
    /// should read as crisp.
    private var panelBlur: CGFloat {
        style == .pill && !visualIsPositioned ? NotchGeometry.pillEnterBlur : 0
    }

    /// Scan-mode content padding for the active style — independently
    /// editable via `NotchGeometry.notchContentPadding*`/`pillContentPadding*`.
    private var scanContentPaddingTop: CGFloat {
        style == .pill ? NotchGeometry.pillContentPaddingTop : NotchGeometry.notchContentPaddingTop
    }

    private var scanContentPaddingLeading: CGFloat {
        style == .pill ? NotchGeometry.pillContentPaddingLeading : NotchGeometry.notchContentPaddingLeading
    }

    private var scanContentPaddingTrailing: CGFloat {
        style == .pill ? NotchGeometry.pillContentPaddingTrailing : NotchGeometry.notchContentPaddingTrailing
    }

    private var scanContentPaddingBottom: CGFloat {
        style == .pill ? NotchGeometry.pillContentPaddingBottom : NotchGeometry.notchContentPaddingBottom
    }

    /// The expansion (size/radius/shadow) curve. Direction-only — any
    /// enter-side delay is realized as a real `Task.sleep` before this is
    /// applied (see `scheduleChoreography()`), not baked into the curve
    /// itself.
    private func expansionAnimation(entering: Bool) -> Animation {
        entering
            ? .spring(response: NotchGeometry.openSpringResponse, dampingFraction: NotchGeometry.openSpringDamping)
            : .spring(response: NotchGeometry.closeSpringResponse, dampingFraction: NotchGeometry.closeSpringDamping)
    }

    /// The slide (position/blur) curve, both directions — a straight-line
    /// off-screen/on-screen move, not a bouncy resize.
    private var slideAnimation: Animation {
        .easeOut(duration: NotchGeometry.pillSlideDuration)
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
                        .padding(.leading, scanContentPaddingLeading)
                        .padding(.trailing, scanContentPaddingTrailing)
                        .padding(.top, scanContentPaddingTop)
                        .padding(.bottom, scanContentPaddingBottom)
                }
            }
            // Content dissolves as the panel shrinks: increasing blur
            // plus a fade, so it melts away rather than being abruptly
            // clipped by the collapsing shape. Rides whatever animation is
            // active on `visualIsExpanded` (set explicitly in
            // `scheduleChoreography()`) — no separate `.animation` needed.
            .blur(radius: visualIsExpanded ? 0 : 14)
            .opacity(visualIsExpanded ? 1 : 0)
            .scaleEffect(visualIsExpanded ? 1 : 0.88)
            .environment(\.notchPanelStyle, style)
        }
        .frame(width: currentSize.width, height: currentSize.height)
        .background(Color.black)
        .clipShape(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius, style: style))
        // Shadow only while expanded — with the window staying on-screen
        // continuously in armed mode, a shadow visible at the *closed* size
        // rendered as a faint dim halo sitting around the real notch even
        // after "dismissing." Radius is fixed rather than growing on hover
        // (only darkness changes) since a larger radius needs more
        // window margin than is reserved and was getting clipped.
        .shadow(color: .black.opacity(visualIsExpanded ? (isHovering ? 0.55 : 0.3) : 0), radius: 9)
        // Drives the per-step resize while onboarding is active —
        // `visualIsExpanded` alone only fires once, on entering/leaving the
        // expanded state. Standalone: nothing else changes at the same
        // moment a step navigates, so this doesn't compete with the
        // explicit choreography above.
        .animation(expansionAnimation(entering: true), value: onboardingController?.panelSize)
        .blur(radius: panelBlur)
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
        .onAppear {
            // Sync without animating — there's nothing to animate *from* on
            // first appearance.
            visualIsExpanded = targetIsExpanded
            visualIsPositioned = targetIsPositioned
        }
        .onChange(of: controller.phase) { _, _ in scheduleChoreography() }
        .onChange(of: controller.isPillDocked) { _, _ in scheduleChoreography() }
        .frame(
            width: NotchGeometry.windowSize(for: style).width,
            height: NotchGeometry.windowSize(for: style).height,
            alignment: .top
        )
    }

    /// Moves `visualIsExpanded`/`visualIsPositioned` toward the controller's
    /// current target, staggering the two when both need to change (see the
    /// file header for why this uses real `Task.sleep` delays rather than
    /// `Animation.delay()`).
    private func scheduleChoreography() {
        let wantExpanded = targetIsExpanded
        let wantPositioned = targetIsPositioned
        choreographyTask?.cancel()
        choreographyTask = nil

        let expandedChanging = wantExpanded != visualIsExpanded
        let positionedChanging = wantPositioned != visualIsPositioned
        guard expandedChanging || positionedChanging else { return }

        guard expandedChanging && positionedChanging else {
            // Only one property is actually moving (e.g. the lock screen
            // docking/undocking at rest, or growing/shrinking in place once
            // already docked) — no partner to stagger against, so it just
            // animates immediately on its own timeline.
            if expandedChanging {
                withAnimation(expansionAnimation(entering: wantExpanded)) { visualIsExpanded = wantExpanded }
            } else {
                withAnimation(slideAnimation) { visualIsPositioned = wantPositioned }
            }
            return
        }

        if wantExpanded {
            // Entering: slide leads immediately, expansion trails after a
            // real delay.
            withAnimation(slideAnimation) { visualIsPositioned = wantPositioned }
            let delay = NotchGeometry.pillEnterExpansionDelay
            let animation = expansionAnimation(entering: true)
            choreographyTask = Task {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                withAnimation(animation) { self.visualIsExpanded = wantExpanded }
            }
        } else {
            // Exiting: shrink leads immediately, slide trails after a real
            // delay.
            withAnimation(expansionAnimation(entering: false)) { visualIsExpanded = wantExpanded }
            let delay = NotchGeometry.pillExitSlideDelay
            let animation = slideAnimation
            choreographyTask = Task {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                withAnimation(animation) { self.visualIsPositioned = wantPositioned }
            }
        }
    }
}
