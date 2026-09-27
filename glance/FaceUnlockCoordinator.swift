//
//  FaceUnlockCoordinator.swift
//  glance
//
//  Connects face recognition to the actual unlock path. Off by default; user opts in after validating accuracy in Face Lab.
//
//  Known limitation: LivenessAnalyzer defeats a photo but not a replayed video (real non-rigid motion looks live) — a successful spoof types the real macOS password.
//

import Foundation
import CoreGraphics
import Observation

@Observable
@MainActor
final class FaceUnlockCoordinator {
    private let pocController: POCController
    let lockMonitor = LockMonitor()
    let camera = CameraManager()
    let pipeline = FaceRecognitionPipeline()

    /// Persisted via GlanceSettings. Setting to false cancels any in-flight scan and disarms the overlay immediately.
    var isEnabled: Bool {
        didSet {
            GlanceSettings.shared.isFaceUnlockEnabled = isEnabled
            if !isEnabled { disarmOverlay() }
        }
    }

    /// Kept independent from Face Lab's own `threshold` so tuning the debug tool never silently changes the real unlock gate.
    var matchThreshold: Float {
        didSet { GlanceSettings.shared.matchThreshold = matchThreshold }
    }
    /// Shares its setting with NotchOverlayController's scanning timeout, so the background loop stops in step with the UI collapsing.
    private var scanWindowDuration: TimeInterval {
        let configured = TimeInterval(GlanceSettings.shared.faceDetectionSeconds)
        return GlanceSettings.shared.requireInfrared ? max(configured, 10) : configured
    }
    /// Requires several consecutive below-threshold frames so a single bad-angle read doesn't trigger the failure animation.
    private let wrongFaceStreakThreshold = 6

    private(set) var statusMessage = "Idle"
    private(set) var lastOutcome: String?
    /// Numeric diagnostics for the latest scan only; no images or embeddings.
    private(set) var lastCheckDetails: String?
    private var diagnosticGeneration = 0

    private var hasArmedForCurrentLock = false
    /// One-shot per lock session — an auto-retry that could itself auto-retry would loop the camera for the whole lock session.
    private var hasAutoRetriedForCurrentLock = false
    private var scanTask: Task<Void, Never>?
    /// Bumped by every `startScanCycle()`; a cycle bails once superseded (see `runScanCycle(generation:)`).
    private var scanGeneration = 0
    /// When the last scan cycle was armed — collapses a single wake into a single arm (see `.wake` branch of `evaluateTrigger`).
    private var lastArmedAt: ContinuousClock.Instant?
    /// One lid-open fires several wake signals within a few hundred ms of each other; anything in this window counts as the same wake.
    private let rearmDebounce: Duration = .seconds(2)
    /// Held separately from `scanTask` since it's scheduled from inside the scan task it follows — reusing `scanTask` would self-cancel it.
    private var autoRetryTask: Task<Void, Never>?
    /// Gap between headless auto-retries, just to keep the camera from restarting in a tight loop.
    private let headlessRetryDelay: Duration = .seconds(1)

    /// When off, no notch/pill presence at all — every overlay call in this file is conditioned on this rather than just skipping the video.
    private var showsUI: Bool { GlanceSettings.shared.showUnlockAnimation }

    /// Reads the space key on the lock screen for the "On space" trigger; only runs while locked + opted in.
    private let spaceKeyMonitor = SpaceKeyMonitor()

    init(pocController: POCController) {
        self.pocController = pocController
        self.isEnabled = GlanceSettings.shared.isFaceUnlockEnabled
        self.matchThreshold = GlanceSettings.shared.matchThreshold
        spaceKeyMonitor.onSpaceKeyDown = { [weak self] in self?.handleSpaceKeyPress() }
        observeLockAndWakeEvents()
        NotificationCenter.default.addObserver(forName: .secureCredentialSessionDidChange, object: nil, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in self?.disarmOverlay() }
        }
    }

    /// Re-subscribes on every change — `withObservationTracking` only fires once per registration.
    private func observeLockAndWakeEvents() {
        withObservationTracking {
            _ = lockMonitor.isScreenLocked
            _ = lockMonitor.wakeEventCount
            _ = lockMonitor.isSleeping
            // Also tracked so screensaver-stop and display-only wakes still wake this up.
            _ = lockMonitor.eventCount
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observeLockAndWakeEvents()
                let event = self.lockMonitor.eventCount
                // Start immediately when CGSession already confirms the lock.
                // If its state is still settling after wake, retry the same
                // event once; a newer event owns its own evaluation.
                await LockTriggerRetry.evaluate(event: event,
                    currentEvent: { self.lockMonitor.eventCount },
                    isArmed: { self.hasArmedForCurrentLock },
                    attempt: { self.evaluateTrigger() },
                    stopRequested: self.lockMonitor.lastEvent == .screenUnlocked || self.lockMonitor.lastEvent == .willSleep,
                    stop: {
                        self.hasArmedForCurrentLock = false
                        self.hasAutoRetriedForCurrentLock = false
                        self.lastArmedAt = nil
                        self.disarmOverlay(reason: self.lockMonitor.lastEvent == .willSleep
                            ? "Face check stopped because the Mac is going to sleep."
                            : "Face check stopped when the screen unlocked.")
                    })
            }
        }
    }

    private func evaluateTrigger() {
        guard LockMonitor.isScreenActuallyLocked() else {
            hasArmedForCurrentLock = false
            hasAutoRetriedForCurrentLock = false
            disarmOverlay()
            return
        }
        guard !lockMonitor.isSleeping else { return }

        // `.wake` (sleep, display sleep, or screensaver stopping) is an explicit "let me back in," so clear the one-shot guard.
        // `isWithinRecentArmBurst` keeps the several wake signals from one lid-open from each re-arming and fighting over the camera.
        if lockMonitor.lastEvent == .wake, !isWithinRecentArmBurst {
            hasArmedForCurrentLock = false
        }

        // Runs before the hasArmedForCurrentLock guard — the space monitor's lifetime is tied to "locked + opted in," not to whether a scan already ran.
        updateSpaceMonitor()

        guard isEnabled, !hasArmedForCurrentLock else { return }
        guard let signal = requiredTrigger(for: lockMonitor.lastEvent) else { return }
        // A pinned display that isn't connected bails entirely rather than showing up elsewhere; "Main display" (nil) always resolves.
        guard NotchGeometry.preferredScreen() != nil else { return }

        guard SecureCredentialManager.isSessionUnlocked else {
            statusMessage = "Face unlock is on, but the session is locked — authenticate once from Password settings first."
            return
        }
        guard SecureCredentialManager.hasStoredPassword() else {
            statusMessage = "Face unlock is on, but no password is stored yet."
            return
        }

        // A deselected trigger means "don't auto-scan for this signal," not "do nothing" — the user can still opt in by hand.
        let shouldAutoScan = GlanceSettings.shared.unlockTriggers.contains(signal)

        // Headless has nothing to arm/hover, so if this signal isn't selected there's nothing to do — and hasArmedForCurrentLock
        // must stay false, or a later selected signal could never fire (nothing else calls arm() to reset it).
        guard showsUI || shouldAutoScan else { return }

        guard arm(autoScan: shouldAutoScan) else { return }
        hasArmedForCurrentLock = true
        lastArmedAt = .now
    }

    /// Whether the last arm was recent enough to be part of the same wake burst rather than a new one.
    private var isWithinRecentArmBurst: Bool {
        guard let lastArmedAt else { return false }
        return ContinuousClock.now - lastArmedAt < rearmDebounce
    }

    /// nil for signals that shouldn't arm anything — including a nil `lastEvent`, or the first observation would fire regardless of user selection.
    private func requiredTrigger(for event: LockEventKind?) -> UnlockTrigger? {
        switch event {
        case .wake: return .onWake
        case .screenLocked: return .onLock
        case .screenUnlocked, .willSleep, nil: return nil
        }
    }

    private func disarmOverlay(reason: String? = nil) {
        if scanTask != nil, lastOutcome == nil, let reason {
            lastOutcome = reason
            statusMessage = reason
        }
        scanTask?.cancel()
        scanTask = nil
        // Bumping makes any cycle still suspended at `await camera.start()` inert, rather than resuming and re-showing the overlay.
        scanGeneration &+= 1
        autoRetryTask?.cancel()
        autoRetryTask = nil
        camera.stop()
        NotchOverlayController.shared.disarm()
        // Covers isEnabled being switched off directly, keeping "disarmed" and "not listening for space" in lockstep.
        spaceKeyMonitor.stop()
    }

    /// Idempotent and safe to call on every lock/wake event. Deliberately does not prompt for Input Monitoring — a missing grant just means "don't listen."
    private func updateSpaceMonitor() {
        let shouldListen = isEnabled
            && GlanceSettings.shared.unlockTriggers.contains(.onSpace)
            && LockMonitor.isScreenActuallyLocked()
            && SpaceKeyMonitor.hasInputMonitoringAccess()
        if shouldListen {
            spaceKeyMonitor.start()
        } else {
            spaceKeyMonitor.stop()
        }
    }

    /// Runs the same gate chain as `evaluateTrigger`, then starts a scan. Independent of `LockMonitor` events, so doesn't touch `hasArmedForCurrentLock`.
    private func handleSpaceKeyPress() {
        guard isEnabled,
              GlanceSettings.shared.unlockTriggers.contains(.onSpace),
              LockMonitor.isScreenActuallyLocked(),
              NotchGeometry.preferredScreen() != nil,
              SecureCredentialManager.isSessionUnlocked,
              SecureCredentialManager.hasStoredPassword()
        else { return }

        // Already looking — swallows auto-repeat/double-presses and lets "On wake"/"On lock" override "On space" with no special-casing.
        guard NotchOverlayController.shared.phase != .scanning else { return }

        guard showsUI else {
            // Headless: no overlay, just scan.
            startScanCycle()
            return
        }
        if NotchOverlayController.shared.isArmed {
            // Closed pill/notch already up — expand and scan, like a hover retry.
            startScanCycle()
        } else {
            arm(autoScan: true)
        }
    }

    /// Either way the overlay still arms — a deselected trigger only skips the automatic scan, leaving hover-to-start available.
    @discardableResult
    private func arm(autoScan: Bool) -> Bool {
        guard isEnabled, !lockMonitor.isSleeping,
              SecureCredentialManager.isSessionUnlocked, LockMonitor.isScreenActuallyLocked() else { return false }
        guard showsUI else {
            // Headless: evaluateTrigger() already guaranteed autoScan is true here, so this is just "start scanning."
            startScanCycle()
            return true
        }
        NotchOverlayController.shared.arm { [weak self] in
            self?.startScanCycle()
        }
        if autoScan {
            startScanCycle()
        }
        return true
    }

    /// Called on arm, and again whenever the overlay hover-activates.
    private func startScanCycle() {
        scanTask?.cancel()
        scanGeneration &+= 1
        let generation = scanGeneration
        scanTask = Task { [weak self] in
            await self?.runScanCycle(generation: generation)
        }
    }

    /// `generation` is what makes overlapping cycles safe: `Task.cancel()` is cooperative, so a superseded cycle still runs to the
    /// end of this function, and its global side effects (`camera.stop()` etc.) could otherwise land on the newer cycle instead
    /// of itself. This was a real bug — a superseded `camera.stop()` queued behind the newer cycle's `startRunning()` made the
    /// camera visibly switch on then die mid-warm-up, leaving the surviving cycle polling a dead session and never unlocking.
    private func runScanCycle(generation: Int) async {
        guard LockMonitor.isScreenActuallyLocked() else { return }

        diagnosticGeneration = generation
        statusMessage = "Starting camera…"
        lastOutcome = nil
        lastCheckDetails = nil
        guard KeystrokeInjector.isAccessibilityTrusted() else {
            statusMessage = "Accessibility permission required. Enable this app in System Settings → Privacy & Security → Accessibility."
            lastOutcome = statusMessage
            return
        }
        let scanStarted = ContinuousClock.now
        await camera.start()
        guard generation == scanGeneration else { return }

        if let error = camera.errorMessage {
            statusMessage = error
            camera.stop()
            return
        }

        // Do not spend the liveness window
        // waiting for the first fresh frame; bound camera warmup separately.
        let warmupDeadline = ContinuousClock.now + .seconds(5)
        while camera.currentFrame.map({ $0.capturedAt >= scanStarted }) != true {
            guard !Task.isCancelled, generation == scanGeneration, isEnabled,
                  LockMonitor.isScreenActuallyLocked() else {
                if generation == scanGeneration { camera.stop() }
                return
            }
            guard ContinuousClock.now < warmupDeadline else {
                camera.stop()
                statusMessage = "The camera did not provide a fresh frame. Try again."
                lastOutcome = statusMessage
                return
            }
            try? await Task.sleep(for: .milliseconds(20))
        }

        let showsUI = self.showsUI
        if showsUI {
            NotchOverlayController.shared.beginScanning(timeout: .seconds(scanWindowDuration))
        }
        statusMessage = "Looking for your face…"
        lastOutcome = nil
        lastCheckDetails = nil

        let outcome = await observeScanWindow(
            deadline: ContinuousClock.now + .seconds(scanWindowDuration),
            requireOverlayScanning: showsUI,
            generation: generation,
            scanStarted: scanStarted,
            cameraReadyAt: .now
        )

        // A newer cycle now owns the camera and overlay — leave both alone, and leave the auto-retry one-shot unspent.
        guard generation == scanGeneration else { return }

        camera.stop()

        switch outcome {
        case .matched:
            // The unlock already happened inside observeScanWindow — this only decides whether anything is shown about it.
            if showsUI {
                NotchOverlayController.shared.finish(success: true)
            }
        case .consistentlyWrongFace:
            statusMessage = "Face not recognized."
            if showsUI {
                NotchOverlayController.shared.finish(success: false)
                statusMessage = "Face not recognized — hover the notch to try again."
                scheduleAutoRetryIfEnabled(after: NotchOverlayController.shared.failureHoldDuration)
            } else {
                scheduleAutoRetryIfEnabled(after: headlessRetryDelay)
            }
        case .spoofSuspected:
            statusMessage = "Couldn't confirm a live face."
            if showsUI {
                NotchOverlayController.shared.finish(success: false)
                statusMessage = "Couldn't confirm a live face — hover the notch to try again."
                scheduleAutoRetryIfEnabled(after: NotchOverlayController.shared.failureHoldDuration)
            } else {
                scheduleAutoRetryIfEnabled(after: headlessRetryDelay)
            }
        case .livenessUnconfirmed:
            statusMessage = "Face recognized, but the live-face check did not finish. Blink or gently turn your head and try again."
            lastOutcome = statusMessage
            if showsUI { NotchOverlayController.shared.finish(success: false) }
        case .infraredFailed(let reason):
            statusMessage = reason
            lastOutcome = reason
            if showsUI { NotchOverlayController.shared.finish(success: false) }
        case .noResolution:
            statusMessage = "No face detected."
            if showsUI {
                // No explicit collapse call: NotchOverlayController's own scanning timeout fires on the same mark and collapses itself.
                statusMessage = "No face detected — hover the notch to try again."
                scheduleAutoRetryIfEnabled(after: NotchOverlayController.shared.collapseAnimationDuration)
            } else {
                scheduleAutoRetryIfEnabled(after: headlessRetryDelay)
            }
        }
    }

    /// `delay` waits out whatever the overlay is still showing so the retry doesn't start underneath the previous outcome.
    private func scheduleAutoRetryIfEnabled(after delay: Duration) {
        guard GlanceSettings.shared.autoRetryOnce, !hasAutoRetriedForCurrentLock else { return }
        hasAutoRetriedForCurrentLock = true
        autoRetryTask?.cancel()
        autoRetryTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            // Re-check rather than trust the delay: the user may have unlocked by password or retried manually while this waited.
            guard LockMonitor.isScreenActuallyLocked(), self.isEnabled else { return }
            if self.showsUI {
                guard NotchOverlayController.shared.phase == .closed else { return }
            }
            self.startScanCycle()
        }
    }

    private enum ScanOutcome {
        case matched
        case consistentlyWrongFace
        /// A deny cue (glare, device rectangle) fired — actively rejected as a spoof regardless of match. Same failure path as `.consistentlyWrongFace`.
        case spoofSuspected
        case livenessUnconfirmed
        case noResolution
        case infraredFailed(String)
    }

    /// Only frames matching the same continuously observed identity contribute to liveness.
    /// Undecided liveness keeps scanning until `deadline`; required IR runs after both RGB gates pass.
    /// `requireOverlayScanning` bails early once the overlay's own timeout collapses the UI — only applied when there is an
    /// overlay, since headlessly `phase` never becomes `.scanning` at all.
    private func observeScanWindow(deadline: ContinuousClock.Instant, requireOverlayScanning: Bool, generation: Int, scanStarted: ContinuousClock.Instant, cameraReadyAt: ContinuousClock.Instant) async -> ScanOutcome {
        let rgbThreshold = matchThreshold
        let infraredRequired = GlanceSettings.shared.requireInfrared
        let configuredLiveness = GlanceSettings.shared.livenessChecksEnabled
        let livenessEnabled = configuredLiveness || infraredRequired
        let liveness = LivenessAnalyzer(skipAbstainingGeometry: true)
        liveness.modeProvider = { infraredRequired ? .heavy : GlanceSettings.shared.livenessMode }
        var consecutiveWrongFaceFrames = 0

        /// Cleared the moment a detected face fails to match, so a latched match can't be handed to whoever steps in next.
        var readyMatch: ScoredIdentity?
        var livenessIdentity: FaceIdentity?
        var livenessConfirmedAt: ContinuousClock.Instant?
        /// Turning liveness off in Settings makes this half permanently ready.
        var livenessConfirmed = !livenessEnabled
        /// Last frame's selected face, passed back so `selectDominantFace` stays on the same person instead of flip-flopping.
        var lastFaceBoundingBox: CGRect?
        /// Cheap way to detect "no new camera frame yet" vs. "fresh frame" — without it a repeat frame would corrupt the liveness motion signal.
        var lastProcessedFrameID: UInt64?
        var recognizedFace = false

        while ContinuousClock.now < deadline, !Task.isCancelled,
              !requireOverlayScanning || NotchOverlayController.shared.phase == .scanning {
            guard LockMonitor.isScreenActuallyLocked(), isEnabled, generation == scanGeneration, matchThreshold == rgbThreshold,
                  infraredRequired == GlanceSettings.shared.requireInfrared,
                  configuredLiveness == GlanceSettings.shared.livenessChecksEnabled else { return .noResolution }

            guard let frame = camera.currentFrame, frame.id != lastProcessedFrameID, frame.capturedAt >= scanStarted else {
                // 20ms keeps the liveness window's sample count high while staying close to the camera's native ~33ms cadence.
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            lastProcessedFrameID = frame.id

            let pipeline = self.pipeline
            let previousBoundingBox = lastFaceBoundingBox
            let outcome = await Task.detached(priority: .userInitiated) { () -> (FaceRecognitionResult, LivenessFrame)? in
                guard let result = try? pipeline.recognize(in: frame.image, preferNear: previousBoundingBox, includeQuality: false) else { return nil }
                let faceCrop = CameraManager.renderCrop(from: frame, imageRect: result.face.boundingBox)
                return (result, LivenessFeatureExtractor.extract(from: result, frame: frame.image, faceCrop: faceCrop))
            }.value

            guard let (result, livenessFrame) = outcome else {
                readyMatch = nil
                livenessIdentity = nil
                liveness.reset()
                livenessConfirmedAt = nil
                livenessConfirmed = !livenessEnabled
                consecutiveWrongFaceFrames = 0
                lastFaceBoundingBox = nil
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            lastFaceBoundingBox = result.face.normalizedBoundingBox

            let scored = pipeline.score(result.embedding, against: FaceEnrollmentStore.shared.activeIdentities)
            let matched = pipeline.bestMatch(in: scored, threshold: rgbThreshold)
            // Evidence belongs to one continuously observed identity, never a
            // previous face or a bystander who supplied a liveness cue.
            if matched?.identity != livenessIdentity || matched == nil {
                liveness.reset()
                livenessConfirmedAt = nil
                livenessConfirmed = !livenessEnabled
                livenessIdentity = matched?.identity
            }
            var confirmingCue: LivenessCue?
            if livenessEnabled, matched != nil {
                lastCheckDetails = "Colour face matched."
                if let glare = livenessFrame.glare {
                    let reading = LivenessCues.glossGlare(livenessFrame)
                    lastCheckDetails = String(format: "Colour face matched. Bright pixels: %.2f%%; concentration: %.2f%%; glare score: %.3f (limit %.3f).",
                        glare.specularFraction * 100, glare.specularClusterRatio * 100,
                        reading.level, LivenessTuning.default.glossLevel)
                }
                let snapshot = liveness.observe(livenessFrame)
                let blink = snapshot.cueStates[.blink]?.reading ?? .none
                let depth = snapshot.cueStates[.depthPose]?.reading ?? .none
                let shape = snapshot.cueStates[.flatVs3D]?.reading ?? .none
                lastCheckDetails = (lastCheckDetails ?? "Colour face matched.") + String(format:
                    " Live-face frames: %d; blink: %.2f; head-depth: %.2f (confidence %.2f); 3D shape: %.2f (confidence %.2f).",
                    snapshot.frameCount, blink.level, depth.level, depth.confidence, shape.level, shape.confidence)
                switch snapshot.decision {
                case .denied:
                    // Overrides everything, including a match and any confirmation that already happened.
                    lastOutcome = snapshot.decision.denialReason
                    return .spoofSuspected
                case .confirmed(let cue):
                    if !livenessConfirmed { livenessConfirmedAt = frame.capturedAt }
                    livenessConfirmed = true
                    confirmingCue = cue
                case .pending:
                    break
                }
            }

            if let matched {
                recognizedFace = true
                consecutiveWrongFaceFrames = 0
                readyMatch = matched
            } else {
                readyMatch = nil
                consecutiveWrongFaceFrames += 1
                if consecutiveWrongFaceFrames >= wrongFaceStreakThreshold {
                    return .consistentlyWrongFace
                }
            }

            if let readyMatch, livenessConfirmed {
                guard !Task.isCancelled, generation == scanGeneration, isEnabled else { return .noResolution }
                if infraredRequired {
                    return await confirmInfrared(for: readyMatch.identity, generation: generation, rgbThreshold: rgbThreshold,
                        evidenceAt: min(frame.capturedAt, livenessConfirmedAt ?? frame.capturedAt), scanStarted: scanStarted, cameraReadyAt: cameraReadyAt)
                }
                statusMessage = "Recognized — unlocking…"
                let livenessNote = livenessEnabled
                    ? (confirmingCue.map { "live via \($0.title)" } ?? "liveness clear")
                    : "liveness off"
                lastOutcome = "Matched \(readyMatch.identity.name) at \(String(format: "%.3f", readyMatch.centroidSimilarity)), \(livenessNote)."
                let injected = await pocController.injectStoredPassword(requireAuthoritativeLock: true) { [weak self] in
                    guard let self else { return false }
                    return !Task.isCancelled && generation == self.scanGeneration && self.isEnabled && self.matchThreshold == rgbThreshold
                        && !GlanceSettings.shared.requireInfrared
                        && configuredLiveness == GlanceSettings.shared.livenessChecksEnabled
                        && FaceEnrollmentStore.shared.activeIdentities.contains(readyMatch.identity)
                }
                return injected ? .matched : .noResolution
            }

            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return recognizedFace && livenessEnabled && !livenessConfirmed ? .livenessUnconfirmed : .noResolution
    }
    private let infraredAnalyzer = InfraredFaceAnalyzer()

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }

    /// RGB identity + heavy liveness have succeeded for this exact snapshot.
    /// Stop AVFoundation before taking the BRIO's USB interfaces, then require
    /// a separate IR match. Missing hardware is a denial, never an RGB fallback.
    private func confirmInfrared(for identity: FaceIdentity, generation: Int, rgbThreshold: Float,
                                 evidenceAt started: ContinuousClock.Instant, scanStarted: ContinuousClock.Instant, cameraReadyAt: ContinuousClock.Instant) async -> ScanOutcome {
        let colourFinishedAt = ContinuousClock.now
        let threshold = GlanceSettings.shared.infraredThreshold
        guard let enrollment = identity.infrared, enrollment.isUsable else {
            return .infraredFailed("Infrared enrollment required for this identity. Open Your Face settings.")
        }
        let service = InfraredServiceManager()
        guard service.enabled else { return .infraredFailed("Infrared camera helper is unavailable or not approved.") }
        if showsUI { NotchOverlayController.shared.beginScanning(timeout: .seconds(15)) }
        statusMessage = "Checking infrared — keep looking at the BRIO…"
        await camera.stopAndWait()
        guard !Task.isCancelled, generation == scanGeneration else { return .noResolution }
        do {
            // Loading Core ML is independent of USB capture; overlap the cold
            // load rather than putting it on the path after the image arrives.
            async let prepared: Void = infraredAnalyzer.prepare()
            let captureStarted = ContinuousClock.now
            let result = try await InfraredServiceManager.capture(allowPermissionPrompt: false)
            let captureElapsed = captureStarted.duration(to: .now).components
            let captureSeconds = Double(captureElapsed.seconds) + Double(captureElapsed.attoseconds) / 1e18
            let analysisStarted = ContinuousClock.now
            try await prepared
            let sample = try await infraredAnalyzer.sample(from: result.image(), captureID: UUID())
            let analysisSeconds = Self.seconds(analysisStarted.duration(to: .now))
            let score = try enrollment.compare(sample)
            let scanElapsed = scanStarted.duration(to: .now).components
            let scanSeconds = Double(scanElapsed.seconds) + Double(scanElapsed.attoseconds) / 1e18
            lastCheckDetails = String(format: "Colour identity and Heavy liveness passed. IR centroid: %.3f; lowest reference: %.3f; required: %.3f. IR capture: %.1fs; total face checks: %.1fs.",
                score.centroid, score.minimumReference, threshold, captureSeconds, scanSeconds)
            let authorized: @MainActor @Sendable () -> Bool = { [weak self] in
                guard let self else { return false }
                let elapsed = started.duration(to: .now).components
                let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
                return !Task.isCancelled && GlanceSettings.shared.requireInfrared
                    && threshold == GlanceSettings.shared.infraredThreshold
                    && self.isEnabled && self.matchThreshold == rgbThreshold
                    && InfraredUnlockPolicy.permits(score: score, threshold: threshold, elapsed: seconds,
                        sameIdentityAndEnrollment: FaceEnrollmentStore.shared.activeIdentities.contains(identity),
                        sameScan: generation == self.scanGeneration,
                        sessionUnlocked: SecureCredentialManager.isSessionUnlocked,
                        screenLocked: LockMonitor.isScreenActuallyLocked(), sleeping: self.lockMonitor.isSleeping,
                        livenessConfirmed: true, helperEnabled: service.isCurrentlyEnabled())
            }
            guard authorized() else { return .infraredFailed("Infrared check did not pass. Use your password or try again.") }
            let injectionStarted = ContinuousClock.now
            let injected = await pocController.injectStoredPassword(requireAuthoritativeLock: true, authorization: authorized)
            if diagnosticGeneration == generation {
                lastCheckDetails = (lastCheckDetails ?? "") + String(format:
                    " Camera startup: %.2fs; colour/liveness: %.2fs; camera handoff: %.2fs; IR analysis: %.2fs; password submission: %.2fs; total to submission: %.2fs.",
                    Self.seconds(scanStarted.duration(to: cameraReadyAt)),
                    Self.seconds(cameraReadyAt.duration(to: colourFinishedAt)), Self.seconds(colourFinishedAt.duration(to: captureStarted)), analysisSeconds,
                    Self.seconds(injectionStarted.duration(to: .now)), Self.seconds(scanStarted.duration(to: .now)))
            }
            guard injected else {
                return .infraredFailed("Face checks passed. " + pocController.statusMessage)
            }
            lastOutcome = "RGB identity and liveness plus same-identity infrared match passed."
            return .matched
        } catch {
            if Task.isCancelled { return .noResolution }
            return .infraredFailed("Infrared check failed: " + error.localizedDescription)
        }
    }

}
