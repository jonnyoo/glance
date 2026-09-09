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
import AppKit

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

    /// Minimal style only: whether the lock glyph is showing its open form.
    /// A mirror of "phase is `.success`" rather than the phase itself, so
    /// the flip can be delayed (`minimalLockUnlockDelay`) to land with the
    /// video's own resolve beat, and so it can be *held* open across the
    /// collapse instead of snapping shut mid-shrink.
    @State private var isMinimalLockOpen = false
    /// The pending delayed unlock, if any.
    @State private var lockUnlockTask: Task<Void, Never>?

    /// Whether the scan "breathing" pulse is currently at its dimmed end.
    /// Only ever mutated inside an explicit `withAnimation`, so it never
    /// jumps — see `startScanPulse()`/`stopScanPulse()`.
    @State private var isScanPulseDimmed = false
    /// The running ping-pong loop while `.scanning`, if any.
    @State private var scanPulseTask: Task<Void, Never>?

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

    /// True when this cycle should render the minimal unlock style: a
    /// width-only widening with a lock glyph and the video in it, rather
    /// than the full-panel expansion. Onboarding always uses the full panel,
    /// and `.none` keeps the full expansion too (it only drops the video) —
    /// so this is specifically `.minimal` scan content.
    private var isMinimalScan: Bool {
        onboardingController == nil && controller.activeUnlockStyle == .minimal
    }

    /// Scan-mode footprint for the active style — independently editable via
    /// `NotchGeometry.notchOpenSize`/`pillOpenSize`.
    private var scanOpenSize: CGSize {
        style == .notch ? NotchGeometry.notchOpenSize : NotchGeometry.pillOpenSize
    }

    /// The minimal style's "expanded" footprint. In notch style the width
    /// grows to add a flank of black either side of the physical cutout,
    /// and the height grows by `minimalNotchHeightBump` — the closed
    /// silhouette itself (the physical notch's own height) can't change,
    /// so this appears as extra black *below* it once expanded.
    private var minimalOpenBodySize: CGSize {
        switch style {
        case .notch:
            return CGSize(
                width: closedBodySize.width + NotchGeometry.minimalNotchFlankWidth * 2,
                height: closedBodySize.height + NotchGeometry.minimalNotchHeightBump
            )
        case .pill:
            return CGSize(
                width: NotchGeometry.minimalPillOpenWidth,
                height: NotchGeometry.minimalPillOpenHeight
            )
        }
    }

    private var openBodySize: CGSize {
        if let onboardingController { return onboardingController.panelSize }
        return isMinimalScan ? minimalOpenBodySize : scanOpenSize
    }

    /// The physical notch's measured size, or `NotchGeometry.pillClosedSize`
    /// — `NotchGeometry.forScreen` already picks the right one per screen.
    private var closedBodySize: CGSize {
        controller.geometry.closedSize
    }

    private var topRadius: CGFloat {
        if visualIsExpanded {
            if isMinimalScan {
                // Pill stays a true capsule as it stretches — the radius
                // tracks the (also animating) minimal height, so the two
                // interpolate together and it never reads as a rounded
                // rectangle mid-flight.
                return style == .notch
                    ? NotchGeometry.minimalNotchTopRadius
                    : minimalOpenBodySize.height / 2
            }
            return style == .notch ? NotchGeometry.openTopRadius : NotchGeometry.pillOpenCornerRadius
        }
        // Half the height is exactly a capsule end, in pill style.
        return style == .notch ? NotchGeometry.closedTopRadius : closedBodySize.height / 2
    }

    private var bottomRadius: CGFloat {
        if visualIsExpanded {
            if isMinimalScan {
                return style == .notch
                    ? NotchGeometry.minimalNotchBottomRadius
                    : minimalOpenBodySize.height / 2
            }
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

    // MARK: - Scan pulse

    /// True only while the camera is actively looking for a face. Success
    /// and failure both leave `.scanning`, which is what ends the pulse —
    /// the resolve animation should play against steady content.
    private var isScanning: Bool {
        controller.phase == .scanning
    }

    private var scanPulseScale: CGFloat {
        isScanPulseDimmed ? NotchGeometry.scanPulseScale : 1
    }

    private var scanPulseOpacity: Double {
        isScanPulseDimmed ? NotchGeometry.scanPulseOpacity : 1
    }

    /// The scan-mode content — minimal or original. The breathing pulse is
    /// applied to the video only in both styles, never to the lock icon
    /// (minimal) or the panel as a whole — in the `.minimal` branch that
    /// means passing it into `MinimalUnlockView` rather than wrapping this
    /// whole `Group`.
    @ViewBuilder
    private var scanContent: some View {
        if isMinimalScan {
            MinimalUnlockView(
                media: controller.media,
                isUnlocked: isMinimalLockOpen,
                // The notch's flare eats `topRadius` of each edge before
                // any real black starts, so the inset is measured from
                // where the flank actually becomes visible.
                edgeInset: NotchGeometry.minimalContentEdgeInset
                    + (style == .notch ? topRadius : 0),
                // Notch's minimal panel is taller (`minimalNotchHeightBump`)
                // — bigger icon/media sizes so that extra room is a
                // deliberate, consistent enlargement rather than an
                // incidental one that depends on exactly how tall a given
                // Mac's physical notch happens to be.
                lockIconSize: style == .notch
                    ? NotchGeometry.minimalNotchLockIconSize : NotchGeometry.minimalLockIconSize,
                mediaWidth: style == .notch
                    ? NotchGeometry.minimalNotchMediaWidth : NotchGeometry.minimalMediaWidth,
                mediaVerticalInset: style == .notch
                    ? NotchGeometry.minimalNotchMediaVerticalInset
                    : NotchGeometry.minimalMediaVerticalInset,
                pulseScale: scanPulseScale,
                pulseOpacity: scanPulseOpacity
            )
        } else {
            ScanAnimationView(media: controller.media)
                .padding(.leading, scanContentPaddingLeading)
                .padding(.trailing, scanContentPaddingTrailing)
                .padding(.top, scanContentPaddingTop)
                .padding(.bottom, scanContentPaddingBottom)
                .scaleEffect(scanPulseScale)
                .opacity(scanPulseOpacity)
        }
    }

    var body: some View {
        ZStack {
            Group {
                if let onboardingController {
                    // Onboarding's step views lay themselves out to exactly
                    // fill `panelSize` — no shared content padding here,
                    // unlike the scan content below.
                    OnboardingNotchView(controller: onboardingController)
                } else {
                    scanContent
                }
            }
            // Content dissolves as the panel shrinks: increasing blur
            // plus a fade, so it melts away rather than being abruptly
            // clipped by the collapsing shape. Rides whatever animation is
            // active on `visualIsExpanded` (set explicitly in
            // `scheduleChoreography()`) — no separate `.animation` needed.
            .blur(radius: visualIsExpanded ? 0 : 40)
            .opacity(visualIsExpanded ? 1 : 0)
            .scaleEffect(visualIsExpanded ? 1 : 0.3)
            .environment(\.notchPanelStyle, style)
        }
        .frame(width: currentSize.width, height: currentSize.height)
        .background(Color.black)
        .clipShape(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius, style: style))
        .background {
            NotchInteractionRegion(
                shape: NotchShape(topRadius: topRadius, bottomRadius: bottomRadius, style: style)
            ) { hovering in
                isHovering = hovering
                if hovering {
                    performHapticFeedback(.generic)
                    controller.activate()
                }
            }
        }
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
        // Move the panel, its shadow, and its interaction region together.
        .offset(y: verticalOffset)
        .animation(.easeOut(duration: 0.18), value: isHovering)
        .onAppear {
            // Sync without animating — there's nothing to animate *from* on
            // first appearance.
            visualIsExpanded = targetIsExpanded
            visualIsPositioned = targetIsPositioned
            updateScanPulse()
            updateMinimalLock()
        }
        .onDisappear {
            scanPulseTask?.cancel()
            scanPulseTask = nil
            lockUnlockTask?.cancel()
            lockUnlockTask = nil
        }
        .onChange(of: controller.phase) { _, newPhase in
            scheduleChoreography()
            updateScanPulse()
            updateMinimalLock()
            if newPhase == .success {
                performHapticFeedback(.levelChange)
            }
        }
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

    // MARK: - Haptics

    /// Trackpad haptic, gated on `GlanceSettings.hapticFeedbackEnabled`.
    /// `defaultPerformer` is the whole-app/whole-trackpad performer — it
    /// isn't tied to this view or its window, so this is safe to call from
    /// any main-thread context, including while this panel isn't key
    /// (hover on the lock screen never makes it key).
    private func performHapticFeedback(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        guard GlanceSettings.shared.hapticFeedbackEnabled else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .default)
    }

    // MARK: - Scan pulse

    private func updateScanPulse() {
        if isScanning {
            startScanPulse()
        } else {
            stopScanPulse()
        }
    }

    // MARK: - Minimal lock glyph

    /// Drives the lock → unlock flip. The animation itself lives on the
    /// glyph (`MinimalUnlockView` applies `.animation(_, value:)`), so
    /// setting the state plainly here is already animated.
    private func updateMinimalLock() {
        let shouldOpen: Bool
        switch controller.phase {
        case .success:
            shouldOpen = true
        case .collapsing:
            // Hold whatever it currently is. Re-locking here would play the
            // shackle snapping shut *while* the panel is visibly shrinking
            // away, which reads as the unlock being undone.
            return
        case .closed, .scanning, .failure, .onboarding:
            shouldOpen = false
        }

        lockUnlockTask?.cancel()
        lockUnlockTask = nil
        guard shouldOpen != isMinimalLockOpen else { return }

        // Only the unlock is delayable; re-locking happens while the panel
        // is closed and invisible, so it may as well be immediate.
        let delay = NotchGeometry.minimalLockUnlockDelay
        guard shouldOpen, delay > 0 else {
            isMinimalLockOpen = shouldOpen
            return
        }
        lockUnlockTask = Task {
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self.isMinimalLockOpen = true
        }
    }

    /// Runs the ping-pong until cancelled, after first waiting out
    /// `entryDelay` so the pulse doesn't start until the panel has actually
    /// finished expanding.
    ///
    /// Each half-cycle is its own finite `withAnimation` rather than one
    /// `.repeatForever(autoreverses:)` — that distinction is the whole
    /// reason this can stop gracefully. A `repeatForever` animation owns the
    /// property for its entire (infinite) lifetime, and removing it snaps
    /// the value back to whatever the model says, which is exactly the
    /// sudden jump this must not do. With discrete half-cycles, the value is
    /// always a plain animatable target, so `stopScanPulse()` can retarget
    /// it mid-flight and SwiftUI interpolates from the current *rendered*
    /// value.
    private func startScanPulse() {
        // Already breathing (or waiting to start) — don't stack a second
        // loop on top.
        guard scanPulseTask == nil else { return }

        // Pill style doesn't even *start* expanding until
        // `pillEnterExpansionDelay` elapses (see `scheduleChoreography()`),
        // so that's added on top here — otherwise the pulse's own start
        // delay would begin counting down while the panel is still sitting
        // there as a pill, before it's even begun growing.
        let entryDelay = (style == .pill ? NotchGeometry.pillEnterExpansionDelay : 0)
            + NotchGeometry.scanPulseStartDelay
        let half = NotchGeometry.scanPulseHalfCycleDuration
        let hold = NotchGeometry.scanPulseHoldDuration
        scanPulseTask = Task {
            try? await Task.sleep(for: .seconds(entryDelay))
            while !Task.isCancelled {
                withAnimation(.easeInOut(duration: half)) { self.isScanPulseDimmed = true }
                try? await Task.sleep(for: .seconds(half + hold))
                guard !Task.isCancelled else { break }

                withAnimation(.easeInOut(duration: half)) { self.isScanPulseDimmed = false }
                try? await Task.sleep(for: .seconds(half + hold))
            }
        }
    }

    /// Ends the pulse and settles back to full scale/opacity from wherever
    /// it currently is.
    ///
    /// Three cases, all handled by the same two lines:
    /// - **Mid-way, heading toward dimmed** (`isScanPulseDimmed == true`):
    ///   retargeting to `false` makes SwiftUI animate from the current
    ///   rendered value straight back to full, reversing without a jump.
    /// - **Sitting at dimmed** (also `true`): same retarget, just starting
    ///   from the extreme.
    /// - **Already at — or already heading toward — full** (`false`): the
    ///   guard returns without touching anything, so a settled panel stays
    ///   put and an in-flight return finishes on its existing curve rather
    ///   than being restarted at a different speed.
    private func stopScanPulse() {
        scanPulseTask?.cancel()
        scanPulseTask = nil
        guard isScanPulseDimmed else { return }
        withAnimation(.easeOut(duration: NotchGeometry.scanPulseSettleDuration)) {
            isScanPulseDimmed = false
        }
    }
}
