//
//  NotchOverlayView.swift
//  glance
//
//  SwiftUI root hosted inside the fixed-size NotchWindow — only content moves/resizes.
//  Two silhouettes per screen (see NotchPanelStyle): `.notch` sits on the physical
//  cutout; `.pill` is a detached island that slides on/off screen (and docks in place
//  on the lock screen instead of sliding).
//
//  Enter/exit choreography (pill only, see `scheduleChoreography()`) staggers slide vs.
//  expansion using real `Task.sleep` delays on separate `@State` mirrors, not two
//  `.animation(value:)` modifiers — those don't stagger reliably, since SwiftUI can't
//  cleanly split which properties belong to which modifier when both fire in one transaction.
//

import SwiftUI
import AppKit

struct NotchOverlayView: View {
    let controller: NotchOverlayController

    @State private var isHovering = false

    /// Visual mirrors of the controller's target state — see the file header for why
    /// these are separate `@State` rather than computed directly.
    @State private var visualIsExpanded = false
    @State private var visualIsPositioned = false
    /// The in-flight trailing half of an enter/exit choreography, if any.
    @State private var choreographyTask: Task<Void, Never>?

    /// Mirrors "phase is `.success`", not the phase itself, so the flip can be delayed
    /// (`minimalLockUnlockDelay`) and held open across the collapse.
    @State private var isMinimalLockOpen = false
    /// The pending delayed unlock, if any.
    @State private var lockUnlockTask: Task<Void, Never>?

    /// Only ever mutated inside an explicit `withAnimation`, so it never jumps.
    @State private var isScanPulseDimmed = false
    /// The running ping-pong loop while `.scanning`, if any.
    @State private var scanPulseTask: Task<Void, Never>?

    private var style: NotchPanelStyle {
        controller.geometry.style
    }

    /// `scheduleChoreography()` compares this against `visualIsExpanded` to decide what needs to move.
    private var targetIsExpanded: Bool {
        switch controller.phase {
        case .closed, .collapsing: return false
        case .scanning, .success, .failure, .onboarding: return true
        }
    }

    /// Notch style is always positioned (the physical notch never travels). Expanded
    /// always implies positioned regardless of the docked flag, so a mid-success
    /// `disarm()` (which undocks) doesn't yank the panel away mid-animation.
    private var targetIsPositioned: Bool {
        if targetIsExpanded { return true }
        if style == .notch { return true }
        return controller.isPillDocked
    }

    /// While onboarding is active, the panel body tracks its step size instead of the
    /// fixed scan-mode footprint — this is what makes the panel grow/shrink per step.
    private var onboardingController: OnboardingController? {
        if case .onboarding(let controller) = controller.content { return controller }
        return nil
    }

    /// Onboarding always uses the full panel, and `.none` keeps the full expansion too
    /// (it only drops the video) — so this is specifically `.minimal` scan content.
    private var isMinimalScan: Bool {
        onboardingController == nil && controller.activeUnlockStyle == .minimal
    }

    private var scanOpenSize: CGSize {
        style == .notch ? NotchGeometry.notchOpenSize : NotchGeometry.pillOpenSize
    }

    /// In notch style the width grows to add flanking black beside the physical cutout;
    /// the height grows since the cutout itself can't, so the bump appears below it.
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

    private var closedBodySize: CGSize {
        controller.geometry.closedSize
    }

    private var topRadius: CGFloat {
        if visualIsExpanded {
            if isMinimalScan {
                // Pill stays a true capsule as it stretches — radius tracks the animating height.
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
                // Uniform corners in pill style — no flare to balance, unlike the notch.
                return NotchGeometry.pillOpenCornerRadius
            }
            return onboardingController?.panelBottomRadius ?? NotchGeometry.openBottomRadius
        }
        return style == .notch ? NotchGeometry.closedBottomRadius : closedBodySize.height / 2
    }

    /// Widened by `flareAllowance` in notch style so the closed state lands exactly on
    /// the physical notch width instead of coming up short by the flare.
    private var currentSize: CGSize {
        let body = visualIsExpanded ? openBodySize : closedBodySize
        let bump: CGFloat = isHovering ? NotchGeometry.hoverBump : 0
        return CGSize(
            width: body.width + NotchGeometry.flareAllowance(topRadius: topRadius, style: style) + bump,
            height: body.height + bump
        )
    }

    /// Top-aligned inside the fixed window frame, so sliding is purely a matter of
    /// where the top edge sits.
    private var verticalOffset: CGFloat {
        guard style == .pill else { return 0 }
        guard visualIsPositioned else {
            return -(closedBodySize.height + NotchGeometry.pillOffscreenSlack)
        }
        return NotchGeometry.pillTopGap
    }

    /// So it resolves into focus as it slides down, rather than snapping in.
    private var panelBlur: CGFloat {
        style == .pill && !visualIsPositioned ? NotchGeometry.pillEnterBlur : 0
    }

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

    /// Direction-only — any enter-side delay is a real `Task.sleep` before this is
    /// applied (see `scheduleChoreography()`), not baked into the curve.
    private func expansionAnimation(entering: Bool) -> Animation {
        entering
            ? .spring(response: NotchGeometry.openSpringResponse, dampingFraction: NotchGeometry.openSpringDamping)
            : .spring(response: NotchGeometry.closeSpringResponse, dampingFraction: NotchGeometry.closeSpringDamping)
    }

    /// A straight-line off-screen/on-screen move, not a bouncy resize.
    private var slideAnimation: Animation {
        .easeOut(duration: NotchGeometry.pillSlideDuration)
    }

    // MARK: - Scan pulse

    /// Success and failure both leave `.scanning`, ending the pulse so the resolve
    /// animation plays against steady content.
    private var isScanning: Bool {
        controller.phase == .scanning
    }

    private var scanPulseScale: CGFloat {
        isScanPulseDimmed ? NotchGeometry.scanPulseScale : 1
    }

    private var scanPulseOpacity: Double {
        isScanPulseDimmed ? NotchGeometry.scanPulseOpacity : 1
    }

    /// The breathing pulse is applied to the video only, never the lock icon or the
    /// whole panel — hence passing it into `MinimalUnlockView` rather than wrapping `Group`.
    @ViewBuilder
    private var scanContent: some View {
        if isMinimalScan {
            MinimalUnlockView(
                media: controller.media,
                isUnlocked: isMinimalLockOpen,
                // The notch's flare eats `topRadius` before any real black starts.
                edgeInset: NotchGeometry.minimalContentEdgeInset
                    + (style == .notch ? topRadius : 0),
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
                    // Onboarding's step views fill `panelSize` themselves — no shared padding here.
                    OnboardingNotchView(controller: onboardingController)
                } else {
                    scanContent
                }
            }
            // Content dissolves (blur + fade) as the panel shrinks, rather than being
            // abruptly clipped by the collapsing shape. Rides the animation already
            // active on `visualIsExpanded` — no separate `.animation` needed.
            .blur(radius: visualIsExpanded ? 0 : 40)
            .opacity(visualIsExpanded ? 1 : 0)
            .scaleEffect(visualIsExpanded ? 1 : 0.3)
            .environment(\.notchPanelStyle, style)
        }
        .frame(width: currentSize.width, height: currentSize.height)
        .background(Color.black)
        .clipShape(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius, style: style))
        // Shadow only while expanded — otherwise it left a faint dim halo around the
        // real notch even while "closed" in armed mode. Radius is fixed rather than
        // growing on hover since a larger radius needs more window margin than is reserved.
        .shadow(color: .black.opacity(visualIsExpanded ? (isHovering ? 0.55 : 0.3) : 0), radius: 9)
        // Drives the per-step resize while onboarding is active — `visualIsExpanded`
        // alone only fires on entering/leaving the expanded state.
        .animation(expansionAnimation(entering: true), value: onboardingController?.panelSize)
        .blur(radius: panelBlur)
        // Applied after the shadow so both travel together, before `.onHover`.
        .offset(y: verticalOffset)
        .animation(.easeOut(duration: 0.18), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                performHapticFeedback(.generic)
                controller.activate()
            }
        }
        .onAppear {
            // Sync without animating — nothing to animate from on first appearance.
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

    /// Staggers the two when both need to change (see file header for why this uses
    /// real `Task.sleep` delays rather than `Animation.delay()`).
    private func scheduleChoreography() {
        let wantExpanded = targetIsExpanded
        let wantPositioned = targetIsPositioned
        choreographyTask?.cancel()
        choreographyTask = nil

        let expandedChanging = wantExpanded != visualIsExpanded
        let positionedChanging = wantPositioned != visualIsPositioned
        guard expandedChanging || positionedChanging else { return }

        guard expandedChanging && positionedChanging else {
            // Only one property is moving — no partner to stagger against.
            if expandedChanging {
                withAnimation(expansionAnimation(entering: wantExpanded)) { visualIsExpanded = wantExpanded }
            } else {
                withAnimation(slideAnimation) { visualIsPositioned = wantPositioned }
            }
            return
        }

        if wantExpanded {
            // Entering: slide leads immediately, expansion trails after a real delay.
            withAnimation(slideAnimation) { visualIsPositioned = wantPositioned }
            let delay = NotchGeometry.pillEnterExpansionDelay
            let animation = expansionAnimation(entering: true)
            choreographyTask = Task {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                withAnimation(animation) { self.visualIsExpanded = wantExpanded }
            }
        } else {
            // Exiting: shrink leads immediately, slide trails after a real delay.
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

    /// `defaultPerformer` isn't tied to this view/window, so this is safe to call even
    /// while this panel isn't key (hover on the lock screen never makes it key).
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

    /// The animation lives on the glyph itself, so setting the state plainly here is
    /// already animated.
    private func updateMinimalLock() {
        let shouldOpen: Bool
        switch controller.phase {
        case .success:
            shouldOpen = true
        case .collapsing:
            // Hold whatever it currently is — re-locking now would read as undoing the unlock.
            return
        case .closed, .scanning, .failure, .onboarding:
            shouldOpen = false
        }

        lockUnlockTask?.cancel()
        lockUnlockTask = nil
        guard shouldOpen != isMinimalLockOpen else { return }

        // Only the unlock is delayable; re-locking happens while invisible anyway.
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

    /// Each half-cycle is its own finite `withAnimation` rather than one
    /// `.repeatForever(autoreverses:)` — a repeatForever owns the property for its
    /// whole lifetime and snaps on removal, whereas discrete half-cycles let
    /// `stopScanPulse()` retarget mid-flight and interpolate from the rendered value.
    private func startScanPulse() {
        // Already breathing (or waiting to start) — don't stack a second loop on top.
        guard scanPulseTask == nil else { return }

        // Pill doesn't start expanding until `pillEnterExpansionDelay` elapses, so
        // that's added on top here too.
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

    /// Retargets to `false` so SwiftUI animates from the current rendered value back to
    /// full without a jump; the guard leaves an already-settled/returning panel alone.
    private func stopScanPulse() {
        scanPulseTask?.cancel()
        scanPulseTask = nil
        guard isScanPulseDimmed else { return }
        withAnimation(.easeOut(duration: NotchGeometry.scanPulseSettleDuration)) {
            isScanPulseDimmed = false
        }
    }
}
