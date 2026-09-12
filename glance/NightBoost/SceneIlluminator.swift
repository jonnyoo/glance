//
//  SceneIlluminator.swift
//  glance
//
//  Turns the Mac's own display into the flood illuminator Face ID gets from hardware: for the duration of a dark-room
//  scan, drives the target display to full brightness and shows a warm panel over its upper part (the password field in
//  the lower third stays clear). Everything is restored on `end()`, which is idempotent and is called from every scan
//  exit path plus disarm — the worst case of a crash mid-scan is a screen left bright, never a stuck panel.
//
//  Lock-screen visibility uses the same SkyLight delegation as the notch (see NotchSkyLight.swift); without it the panel
//  is simply invisible while locked and only the brightness boost applies.
//

import AppKit

@MainActor
final class SceneIlluminator {
    static let shared = SceneIlluminator()

    /// How much of the screen height, measured from the top, the light panel covers. Deliberately the top third only:
    /// loginwindow draws the avatar and password field around the vertical middle, and a panel over that would hide the
    /// manual fallback exactly when face unlock is struggling. The top band is also nearest the camera, so it is the
    /// most useful third to light anyway.
    static let coverageFraction: CGFloat = 0.38
    /// Not fully opaque so the wallpaper still ghosts through and it reads as "a light came on", not "the screen broke".
    static let panelAlpha: CGFloat = 0.88
    /// The Mac's camera exposes no controllable exposure mode (every `isExposureModeSupported` is false), so the ISP's
    /// own auto-exposure is the only thing tracking this light. Fading in slowly enough for it to follow is what keeps
    /// highlights from railing to neutral white and tripping the glare deny cue — see `IlluminationPanel.lightColor`.
    static let fadeInDuration: TimeInterval = 0.8
    static let fadeOutDuration: TimeInterval = 0.20
    /// Fade plus a margin for auto-exposure to converge. Frames inside this window are skipped by the scan loop rather
    /// than judged, since a half-lit frame is bad evidence for both recognition and liveness.
    static let settleDuration: Duration = .milliseconds(1300)
    /// Brightness during a scan. Not 1.0: the point is enough light to expose a face, and the last stop mostly buys
    /// blown specular highlights off glasses, which is precisely what the glare deny cue rejects as a spoof.
    private static let boostedBrightness: Float = 0.9

    private(set) var isActive = false
    /// When the light was switched on, for `isSettling`.
    private var litAt: ContinuousClock.Instant?

    /// True while the light is still coming up and exposure has not caught up. The scan loop skips these frames.
    var isSettling: Bool {
        guard isActive, let litAt else { return false }
        return ContinuousClock.now - litAt < Self.settleDuration
    }

    private var panel: IlluminationPanel?
    private var isSkyLightDelegated = false
    /// Display + brightness as found at `begin`, restored verbatim at `end`.
    private var restoreBrightness: (display: CGDirectDisplayID, value: Float)?
    /// Retries a refused restore without needing another scan to come along. Bounded, so a permanently unwritable
    /// display costs a couple of seconds of attempts rather than a task that never ends.
    private var restoreRetryTask: Task<Void, Never>?
    private static let restoreRetryAttempts = 6
    private static let restoreRetryDelay: Duration = .milliseconds(400)

    private init() {
        // A quit mid-scan (menu bar Quit, a Sparkle update relaunch, logout) would otherwise leave the display pinned at
        // full brightness with no app left to restore it. `willTerminate` is delivered on the main thread before exit.
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { SceneIlluminator.shared.restoreImmediately() }
        }
    }

    /// Synchronous teardown for paths that have no time for a fade — app termination. Ordinary scan exits use `end()`.
    func restoreImmediately() {
        if isActive {
            isActive = false
            litAt = nil
            if let panel {
                if isSkyLightDelegated, let skyLight = NotchSkyLight.shared {
                    skyLight.undelegate(panel)
                }
                isSkyLightDelegated = false
                panel.orderOut(nil)
            }
        }
        // One synchronous attempt and no retry task: the process is going away, so there is nothing left to run it.
        restoreRetryTask?.cancel()
        attemptBrightnessRestore()
    }

    /// No-op if already lit. `screen` is where the light goes — normally the display the camera lives on.
    func begin(on screen: NSScreen) {
        guard !isActive else { return }
        isActive = true
        litAt = .now

        boostBrightness(of: screen)
        showPanel(on: screen)
    }

    /// Safe to call any number of times, from any exit path.
    func end() {
        if isActive {
            isActive = false
            litAt = nil
            hidePanel()
        }
        // Outside the `isActive` branch on purpose: a restore refused by a previous scan is still owed, and every
        // caller of this method guards on `isActive`, so gating the retry on it would strand the display forever.
        restoreBrightnessIfNeeded()
    }

    // MARK: - Brightness

    private func boostBrightness(of screen: NSScreen) {
        guard let control = DisplayBrightnessControl.shared,
              let display = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              control.canChange(display),
              let current = control.brightness(of: display)
        else { return }
        // Only remember a value we will actually change, so `end` never "restores" a brightness the user set themselves.
        // Flush anything a previous scan still owes before recording a new baseline, and refuse to boost again while
        // that is unresolved: `current` would be our own boosted value, so recording it would make the display's
        // brightness permanently ours.
        restoreRetryTask?.cancel()
        attemptBrightnessRestore()
        guard restoreBrightness == nil else { return }

        guard current < Self.boostedBrightness else { return }
        restoreBrightness = (display, current)
        control.set(Self.boostedBrightness, on: display)
    }

    /// Attempts the restore, keeping the record if it is refused, and schedules a bounded retry when it is.
    private func restoreBrightnessIfNeeded() {
        guard restoreBrightness != nil else { return }
        guard !attemptBrightnessRestore() else { return }

        restoreRetryTask?.cancel()
        restoreRetryTask = Task { [weak self] in
            for _ in 0..<Self.restoreRetryAttempts {
                try? await Task.sleep(for: Self.restoreRetryDelay)
                guard !Task.isCancelled, let self, self.restoreBrightness != nil else { return }
                if self.attemptBrightnessRestore() { return }
            }
        }
    }

    /// The record is cleared only once the write is confirmed. Clearing first would make a single refused restore
    /// permanent — the app would have forgotten the brightness the user actually had.
    @discardableResult
    private func attemptBrightnessRestore() -> Bool {
        guard let pending = restoreBrightness else { return true }
        guard let control = DisplayBrightnessControl.shared, control.canChange(pending.display) else { return false }
        guard control.set(pending.value, on: pending.display) else { return false }
        restoreBrightness = nil
        return true
    }

    // MARK: - Panel

    private func showPanel(on screen: NSScreen) {
        let frame = screen.frame
        let height = (frame.height * Self.coverageFraction).rounded()
        let rect = NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)

        let panel: IlluminationPanel
        if let existing = self.panel {
            panel = existing
            panel.setFrame(rect, display: false)
        } else {
            panel = IlluminationPanel(contentRect: rect)
            self.panel = panel
        }

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        if LockMonitor.isScreenActuallyLocked(), let skyLight = NotchSkyLight.shared {
            skyLight.delegate(panel)
            isSkyLightDelegated = true
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Self.fadeInDuration
            panel.animator().alphaValue = Self.panelAlpha
        }
    }

    private func hidePanel() {
        guard let panel else { return }
        let wasDelegated = isSkyLightDelegated
        isSkyLightDelegated = false
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = Self.fadeOutDuration
            panel.animator().alphaValue = 0
        }, completionHandler: {
            Task { @MainActor in
                // A `begin` may have raced in during the fade — leave its panel alone.
                guard !self.isActive else { return }
                if wasDelegated, let skyLight = NotchSkyLight.shared {
                    skyLight.undelegate(panel)
                }
                panel.orderOut(nil)
            }
        })
    }
}
