//
//  EnrollmentSweepWindowController.swift
//  glance
//
//  Owns the full-screen, click-through sweep overlay shown during guided
//  enrollment. Deliberately separate from NotchOverlay — the notch panel
//  keeps the camera and tick ring, while directional guidance lives on a
//  window that covers the preferred screen.
//
//  One borderless panel on `NotchGeometry.preferredScreen()` only, layered
//  just below NotchWindow (`.mainMenu + 3`) so the camera panel always
//  composites on top of the light.
//

import AppKit
import SwiftUI

@MainActor
final class EnrollmentSweepWindowController {
    @Observable
    final class Host {
        var isPresented = false
        let controller: OnboardingController

        init(controller: OnboardingController) {
            self.controller = controller
        }
    }

    private var window: NSPanel?
    private var host: Host?
    private var dismissTask: Task<Void, Never>?

    func present(for controller: OnboardingController) {
        dismissTask?.cancel()
        dismissTask = nil
        tearDownWindow()

        guard let screen = NotchGeometry.preferredScreen() else { return }

        let host = Host(controller: controller)
        host.isPresented = true

        let hostingView = NSHostingView(rootView: EnrollmentSweepOverlay(host: host))
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: screen.frame.size)

        let window = makePanel(on: screen, contentView: hostingView)
        window.orderFrontRegardless()

        self.host = host
        self.window = window
    }

    /// One-shot variant for the intro screen's single top-to-bottom
    /// flourish — unlike `present(for:)`, this isn't pose-driven or
    /// continuous (no `Host`, nothing tracking `currentPose`/`guideVisible`):
    /// it shows exactly one direction once, then tears itself down on a
    /// timer sized to the sweep's own animation length, with no external
    /// `dismiss()` call needed. Still the same full-screen panel as guided
    /// enrollment, not confined to the small notch content — that's the
    /// whole point of using this window controller instead of a plain
    /// SwiftUI overlay inside the step view.
    func presentOnce(direction: EnrollmentSweepDirection) {
        dismissTask?.cancel()
        dismissTask = nil
        tearDownWindow()

        guard let screen = NotchGeometry.preferredScreen() else { return }

        let hostingView = NSHostingView(rootView: EnrollmentDirectionSweep(direction: direction))
        hostingView.sizingOptions = []
        hostingView.frame = NSRect(origin: .zero, size: screen.frame.size)

        let window = makePanel(on: screen, contentView: hostingView)
        window.orderFrontRegardless()
        self.window = window

        dismissTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(OnboardingMetrics.introSweepAutoDismissDelay))
            guard let self, !Task.isCancelled else { return }
            self.tearDownWindow()
            self.dismissTask = nil
        }
    }

    /// Shared panel setup between `present(for:)` and `presentOnce(direction:)`
    /// — everything except what's actually hosted inside it. Both callers
    /// set `sizingOptions = []` and an explicit `frame` on their hosting
    /// view before calling this: empty/near-empty SwiftUI roots report a
    /// zero intrinsic size, and a hosting view left to size to that
    /// collapses the window, compositing the sweep into nothing.
    private func makePanel(on screen: NSScreen, contentView: NSView) -> NSPanel {
        let window = NSPanel(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isMovable = false
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.ignoresMouseEvents = true
        // One below NotchWindow's `.mainMenu + 3` so the notch panel
        // always reads on top of the sweep, with no masking needed.
        window.level = .mainMenu + 2
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = contentView
        window.setFrame(screen.frame, display: true)
        return window
    }

    func dismiss() {
        dismissTask?.cancel()
        guard window != nil, let host else {
            tearDownWindow()
            return
        }
        host.isPresented = false
        dismissTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(OnboardingMetrics.sweepFadeOut))
            guard !Task.isCancelled else { return }
            tearDownWindow()
            dismissTask = nil
        }
    }

    private func tearDownWindow() {
        window?.orderOut(nil)
        window = nil
        host = nil
    }
}

// MARK: - Overlay root

private struct EnrollmentSweepOverlay: View {
    @Bindable var host: EnrollmentSweepWindowController.Host
    @State private var playingDirection: EnrollmentSweepDirection?
    @State private var playTask: Task<Void, Never>?

    var body: some View {
        // Read observable fields in `body` (not only via helpers) so the
        // hosting view actually subscribes to pose / visibility changes.
        let pose = host.controller.currentPose
        let presented = host.isPresented
        let guiding = host.controller.guideVisible
        let tooFar = host.controller.isTooFar
        let checkmark = host.controller.showCheckmark
        let direction = pose.flatMap(EnrollmentSweepDirection.init(pose:))
        let canPlay = presented && guiding && !tooFar && !checkmark
        let isVisible = canPlay && playingDirection != nil

        ZStack {
            // Gives the hosting view a real expanding child so layout fills
            // the panel even while the first (center) pose has no sweep.
            Color.clear
            if isVisible, let playingDirection {
                EnrollmentDirectionSweep(direction: playingDirection)
                    .id(playingDirection)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: direction, initial: true) { _, newDirection in
            scheduleSweep(newDirection, canPlay: canPlay)
        }
        .onChange(of: canPlay) { _, playable in
            if !playable {
                playTask?.cancel()
                playingDirection = nil
            } else {
                scheduleSweep(direction, canPlay: true)
            }
        }
        .animation(
            .easeInOut(duration: OnboardingMetrics.sweepDirectionCrossfade),
            value: playingDirection
        )
        .animation(
            .easeInOut(
                duration: isVisible
                    ? OnboardingMetrics.sweepFadeIn
                    : OnboardingMetrics.sweepFadeOut
            ),
            value: isVisible
        )
        .allowsHitTesting(false)
    }

    private func scheduleSweep(_ newDirection: EnrollmentSweepDirection?, canPlay: Bool) {
        playTask?.cancel()
        guard canPlay, let newDirection else {
            playingDirection = nil
            return
        }
        playingDirection = nil
        playTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(OnboardingMetrics.sweepPoseDelay))
            guard !Task.isCancelled else { return }
            playingDirection = newDirection
        }
    }
}
