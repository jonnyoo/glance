//
//  NotchOverlayController.swift
//  glance
//
//  The only file other code should touch to show the notch overlay.
//
//  Two ways to drive it:
//  - One-shot (`present()` / `finish(success:)`): used by OnboardingController
//    and Face Lab's preview buttons. The window fully hides after resolving.
//  - Armed (`arm(onActivate:)` / `disarm()`): used by FaceUnlockCoordinator
//    for the real lock-screen flow. While armed, the window never actually
//    hides — it stays on-screen and shrinks to the closed notch silhouette,
//    which is what lets hovering the (visually closed) notch area wake it
//    back up. `disarm()` is the only thing that truly orders it out.
//
//  Interaction is hover-driven, not click-driven: a non-activating panel
//  needs a first click just to gain enough focus for a second click to
//  register, which is exactly the "have to double-click" bug hovering
//  avoids — hover events don't need the window to become key at all.
//

import AppKit
import SwiftUI
import Observation

@Observable
@MainActor
final class NotchOverlayController {
    /// One overlay window for the whole app — the triggers (FaceUnlockCoordinator,
    /// OnboardingController, Face Lab's preview buttons) never run concurrently
    /// in practice, but sharing one instance makes that guaranteed rather than
    /// incidental.
    static let shared = NotchOverlayController()

    enum Phase: Equatable {
        /// Closed silhouette. While armed, the window is still on-screen
        /// here (hover-reactive); while not armed, the window is ordered out.
        case closed
        /// Expanded, showing the idle still image — actively looking for a face.
        case scanning
        /// Success animation playing, then auto-collapses.
        case success
        /// Failure animation playing/held; collapses after a hold unless
        /// the user hovers first to retry.
        case failure
        case collapsing
        /// Hosting the multi-step onboarding flow — expanded, resizing per
        /// step, driven entirely by the hosted OnboardingController rather
        /// than this controller's own resolve/timeout machinery.
        case onboarding
    }

    /// What the panel is showing. `.scan` is the pre-existing Face ID-style
    /// video/still (armed lock-screen flow, Face Lab previews); `.onboarding`
    /// hosts the redesigned notch-native onboarding flow. Kept as one enum
    /// (rather than two independent optionals) so exactly one is ever active.
    enum Content: Equatable {
        case scan(ScanMedia)
        case onboarding(OnboardingController)

        static func == (lhs: Content, rhs: Content) -> Bool {
            switch (lhs, rhs) {
            case (.scan(let a), .scan(let b)): return a == b
            case (.onboarding(let a), .onboarding(let b)): return a === b
            default: return false
            }
        }
    }

    private(set) var phase: Phase = .closed
    private(set) var content: Content = .scan(.idle)
    /// Read-only convenience for the scan-mode view/callers — `.idle` while
    /// onboarding owns the panel.
    var media: ScanMedia {
        if case .scan(let media) = content { return media }
        return .idle
    }
    private(set) var geometry: NotchGeometry = .forMainScreen()
    /// Read by the view for the hover-driven size/shadow bump — irrelevant
    /// to the phase state machine itself.
    private(set) var isArmed = false

    /// What a hover-driven activation should do — set by `arm()` (persists
    /// across scan cycles) or by one-shot `present(onRetry:)` (single use).
    private var onActivate: (() -> Void)?

    private let windowController = NotchWindowController()
    private var resolveTask: Task<Void, Never>?
    private var scanTimeoutTask: Task<Void, Never>?

    /// True once the window has been shown and rendered at least once.
    /// Guards `primeWindowIfNeeded` so the extra render pass only ever
    /// happens on the very first show.
    private var hasPrimedWindow = false

    /// Matches the success asset duration (~1.22s) plus a short ~0.5s beat
    /// so the final frame is actually read before collapsing.
    private let successHoldDuration: Duration = .milliseconds(1_700)
    /// How long a held failure frame waits for a hover-retry before quietly
    /// collapsing on its own.
    private let failureHoldDuration: Duration = .seconds(5)
    /// How long `.scanning` waits with no resolution before quietly
    /// collapsing — no failure animation, since nothing conclusive happened.
    private let scanTimeoutDuration: Duration = .seconds(5)
    /// Long enough for the closing spring to fully settle before the window
    /// is ordered out (or, while armed, before it's just left at rest,
    /// closed) — collapsing the *state* early is what made the window
    /// visibly "pop" out of existence instead of shrinking away.
    private let collapseAnimationDuration: Duration = .milliseconds(700)

    private init() {
        windowController.contentView = NSHostingView(rootView: NotchOverlayView(controller: self))
    }

    // MARK: - Armed mode (FaceUnlockCoordinator)

    /// Arms the overlay for the lock-screen flow: shows the window and
    /// keeps it up (closed or open) until `disarm()`. `onActivate` runs
    /// whenever the user hovers the closed notch, or hovers a held failure
    /// frame — in both cases, "start scanning again" is the right response.
    func arm(onActivate: @escaping () -> Void) {
        isArmed = true
        self.onActivate = onActivate
        geometry = windowController.currentGeometry
        phase = .closed
        content = .scan(.idle)
        windowController.show()
        hasPrimedWindow = true // already shown+rendered while closed, same effect as primeWindowIfNeeded
        updateInteractivity()
    }

    /// Truly hides the window. Only call this once the lock-screen attempt
    /// is completely done (unlocked, or the feature was turned off) —
    /// while armed, resolving an attempt goes back to `.closed`, not this.
    ///
    /// If a success/collapse sequence is already resolving — exactly what
    /// happens the instant the real unlock lands, since that's what fires
    /// this — let it finish naturally instead of yanking it away. Setting
    /// `isArmed = false` here is still enough: the already-scheduled
    /// `collapse()` (from `finish(success:)`) checks `isArmed` itself once
    /// its hold expires, and will hide for real then. Cancelling that task
    /// and hiding immediately is exactly what made the window vanish before
    /// the unlock animation or the shrink had a chance to play.
    func disarm() {
        isArmed = false
        onActivate = nil
        guard phase != .success, phase != .collapsing else { return }
        resolveTask?.cancel(); resolveTask = nil
        scanTimeoutTask?.cancel(); scanTimeoutTask = nil
        phase = .closed
        content = .scan(.idle)
        windowController.setInteractive(false)
        windowController.hide()
    }

    /// Begins a scanning window: shows the idle still, and auto-collapses
    /// back to closed after `scanTimeoutDuration` if nothing resolves it —
    /// silently, no failure animation, since "no face seen" isn't a wrong
    /// answer, just no answer.
    func beginScanning() {
        resolveTask?.cancel(); resolveTask = nil
        scanTimeoutTask?.cancel()
        geometry = windowController.currentGeometry
        content = .scan(.idle)
        phase = .scanning
        updateInteractivity()

        scanTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: self?.scanTimeoutDuration ?? .seconds(5))
            guard let self, !Task.isCancelled, self.phase == .scanning else { return }
            await self.collapse()
        }
    }

    // MARK: - Window priming (first show only)

    /// `present()` and `presentOnboarding()` both set an already-expanded
    /// phase *before* calling `show()`. On the very first show ever, that
    /// means the window is created and rendered for the first time already
    /// in its expanded state — there's no previously-composited "closed"
    /// frame for SwiftUI to animate away from, so the panel just appears
    /// already-open instead of visibly growing into place. (`arm()` doesn't
    /// have this problem: it already sets `.closed` before `show()`, and the
    /// real expand happens later via `beginScanning()`, after an `await`
    /// hop gives AppKit time to render the closed frame first.)
    ///
    /// This runs the window through one real closed-state show+render pass
    /// before `completion` sets the caller's actual target phase — but only
    /// on the first call ever; every later call already has a real prior
    /// frame (even a closed one left over from a previous `hide()`) to
    /// animate from, so `completion` runs synchronously as before.
    private func primeWindowIfNeeded(_ completion: @escaping () -> Void) {
        guard !hasPrimedWindow else {
            completion()
            return
        }
        hasPrimedWindow = true
        content = .scan(.idle)
        phase = .closed
        windowController.show()
        windowController.displaySynchronously()
        DispatchQueue.main.async(execute: completion)
    }

    // MARK: - One-shot mode (onboarding, Face Lab preview)

    /// Shows the overlay in its scanning state. Safe to call again while
    /// already visible. `onRetry` runs if the attempt fails and the user
    /// hovers the overlay; pass nil to just collapse on hover instead.
    func present(onRetry: (() -> Void)? = nil) {
        isArmed = false
        onActivate = onRetry
        resolveTask?.cancel(); resolveTask = nil
        scanTimeoutTask?.cancel(); scanTimeoutTask = nil
        geometry = windowController.currentGeometry
        primeWindowIfNeeded { [weak self] in
            guard let self else { return }
            content = .scan(.idle)
            phase = .scanning
            windowController.show()
            updateInteractivity()
        }
    }

    // MARK: - Onboarding mode (OnboardingController)

    /// Hands the panel to the redesigned notch-native onboarding flow. Sizing
    /// and content from here on are entirely driven by `controller` — this
    /// object only owns the window's visibility and interactivity while
    /// `.onboarding` is the active phase.
    func presentOnboarding(_ controller: OnboardingController) {
        isArmed = false
        onActivate = nil
        resolveTask?.cancel(); resolveTask = nil
        scanTimeoutTask?.cancel(); scanTimeoutTask = nil
        geometry = windowController.currentGeometry
        primeWindowIfNeeded { [weak self] in
            guard let self else { return }
            content = .onboarding(controller)
            phase = .onboarding
            windowController.show()
            updateInteractivity()
        }
    }

    /// Gracefully shrinks the onboarding panel away and hides the window —
    /// the same collapse feel as the scan flow's `collapse()`, but scoped to
    /// onboarding so a scan cycle starting concurrently can't be interrupted
    /// by it (guarded by re-checking `content` after the animation delay).
    func dismissOnboarding() {
        guard case .onboarding = content else { return }
        Task { [weak self] in
            guard let self else { return }
            self.phase = .collapsing
            self.updateInteractivity()
            try? await Task.sleep(for: self.collapseAnimationDuration)
            guard case .onboarding = self.content else { return }
            self.content = .scan(.idle)
            self.phase = .closed
            self.windowController.hide()
        }
    }

    // MARK: - Resolving (shared by both modes)

    /// Resolves the current attempt. Success plays its animation and then
    /// collapses on its own; failure plays its animation and holds until
    /// either the hold expires or the user hovers to retry.
    func finish(success: Bool) {
        resolveTask?.cancel()
        scanTimeoutTask?.cancel()

        // "Play unlock animation" off just skips the success/failure video
        // — the phase (and hence the failure hover-to-retry behavior) is
        // unaffected, only what's shown while resolving.
        let shouldAnimate = GlanceSettings.shared.playUnlockAnimation
        content = shouldAnimate ? .scan(success ? .success : .failure) : .scan(.idle)
        phase = success ? .success : .failure
        updateInteractivity()

        let hold = shouldAnimate ? (success ? successHoldDuration : failureHoldDuration) : Duration.milliseconds(400)
        resolveTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: hold)
            guard !Task.isCancelled else { return }
            await self.collapse()
        }
    }

    /// Hover-driven activation: wakes from a closed/armed state, or retries
    /// from a held failure frame. No-op during scanning/success/collapsing —
    /// hovering then is just the visual bump, nothing to trigger.
    func activate() {
        switch phase {
        case .closed, .failure:
            guard let onActivate else {
                if phase == .failure { Task { await collapse() } }
                return
            }
            resolveTask?.cancel(); resolveTask = nil
            if !isArmed {
                content = .scan(.idle)
                phase = .scanning
                updateInteractivity()
            }
            onActivate()
        case .scanning, .success, .collapsing, .onboarding:
            break
        }
    }

    /// Collapses gracefully: animates shut, then either leaves the window
    /// at rest (closed, still on-screen, hover-reactive) if armed, or
    /// orders it out entirely if not.
    func collapse() async {
        guard phase != .closed, phase != .collapsing else { return }
        phase = .collapsing
        updateInteractivity()
        try? await Task.sleep(for: collapseAnimationDuration)
        guard phase == .collapsing else { return }

        content = .scan(.idle)
        if isArmed {
            phase = .closed
            updateInteractivity()
        } else {
            phase = .closed
            windowController.hide()
        }
    }

    /// Tears the overlay down without any resolve animation. Deliberately a
    /// no-op while success/collapsing is already in flight — interrupting
    /// that is exactly what once made the window vanish abruptly instead of
    /// shrinking away (unlocking fires a cancel at the same moment the
    /// success animation is finishing).
    func dismissImmediately() {
        guard phase != .success, phase != .collapsing else { return }
        resolveTask?.cancel(); resolveTask = nil
        scanTimeoutTask?.cancel(); scanTimeoutTask = nil
        phase = .closed
        content = .scan(.idle)
        windowController.setInteractive(false)
        windowController.hide()
    }

    private func updateInteractivity() {
        // Hover must register whenever there's something for it to do:
        // waking from closed-armed, or retrying a held failure. Otherwise
        // click-through, so the overlay never intercepts anything it
        // doesn't need to. Onboarding additionally needs the window to
        // become *key* so the password step's text field can receive
        // keystrokes.
        windowController.setInteractive(isArmed || phase == .failure || phase == .onboarding, key: phase == .onboarding)
    }
}
