//
//  AppController.swift
//  FaceUnlock
//
//  Owns all long-lived app state: camera, face service, lock monitor, settings,
//  and the auto-unlock orchestration. ContentView is just a presentation layer.
//

import Foundation
import SwiftUI
import Observation
import CoreVideo
import AppKit
import Vision

// MARK: - Shared UI types (also used by ContentView for display)

struct LiveAnalysis {
    let yaw: Float
    let roll: Float
    let quality: Float
    let faceWidth: CGFloat
}

struct LiveSimilarity {
    let centroid: Float
    let maxIndividual: Float
    let threshold: Float
}

struct LiveLiveness {
    let yawRange: Float
    let rollRange: Float
    let threshold: Float
    let samplesCollected: Int
    let minSamples: Int
    let isLive: Bool
}

enum ActionStatus {
    case idle
    case enrolled(EnrollmentReport)
    case verifiedAndLive(VerificationResult)
    case noMatch(VerificationResult)
    case cancelled
    case info(String)
    case failure(String)
}

enum UnlockTrigger {
    case autoOnWake
    case autoOnFraming
    case autoOnUserInput
}

struct FramingPresence: Equatable {
    enum Position: Equatable {
        case noFace
        case offCenter
        case tooSmall
        case tooLarge
        case good
    }
    let position: Position
}

enum ScanOutcome {
    case matched(VerificationResult)
    case noMatchInTime(VerificationResult)
    case noFaceFound
}

// MARK: - AppController

@Observable
@MainActor
final class AppController {
    // Long-lived services
    let camera = CameraManager()
    let service = FaceEnrollmentService()
    let lockMonitor = LockMonitor()

    // User-tunable settings — all persisted to UserDefaults.
    var autoUnlockEnabled: Bool {
        didSet { UserDefaults.standard.set(autoUnlockEnabled, forKey: Self.autoUnlockEnabledPrefKey) }
    }
    var autoUnlockStartDelaySeconds: Double {
        didSet { UserDefaults.standard.set(autoUnlockStartDelaySeconds, forKey: Self.autoUnlockDelayPrefKey) }
    }
    var matchThreshold: Float {
        didSet { UserDefaults.standard.set(Double(matchThreshold), forKey: Self.matchThresholdPrefKey) }
    }
    /// Delay between a successful match and the keystroke injection. 0 means fire
    /// immediately — correct for the lock screen, where the password field is already focused.
    var injectionDelaySeconds: Double {
        didSet { UserDefaults.standard.set(injectionDelaySeconds, forKey: Self.injectionDelayPrefKey) }
    }

    // Live state observed by ContentView for UI feedback
    var status: ActionStatus = .idle
    var isWorking: Bool = false
    var isVerifying: Bool = false
    var liveAnalysis: LiveAnalysis? = nil
    var liveSimilarity: LiveSimilarity? = nil
    var liveLivenessState: LiveLiveness? = nil
    var liveError: String? = nil

    // Setup state
    var hasStoredPassword: Bool = PasswordVault.hasStoredPassword()
    var accessibilityGranted: Bool = KeystrokeInjector.isAccessibilityTrusted()
    var isSessionUnlocked: Bool = PasswordVault.isSessionUnlocked
    var sessionUnlockError: String? = nil

    // Icon placement — persisted across launches.
    private static let dockPrefKey = "FaceUnlock.showInDock"
    private static let menuBarPrefKey = "FaceUnlock.showInMenuBar"
    private static let autoFramingPrefKey = "FaceUnlock.autoFramingEnabled"

    // Auto-unlock & detection settings — also persisted.
    private static let autoUnlockEnabledPrefKey = "FaceUnlock.autoUnlockEnabled"
    private static let autoUnlockDelayPrefKey = "FaceUnlock.autoUnlockStartDelaySeconds"
    private static let matchThresholdPrefKey = "FaceUnlock.matchThreshold"
    private static let injectionDelayPrefKey = "FaceUnlock.injectionDelaySeconds"

    // Auto-framing watcher — when enabled, polls camera frames for face
    // position and auto-triggers a scan when face is centered + sized.
    var autoFramingEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoFramingEnabled, forKey: Self.autoFramingPrefKey)
            if autoFramingEnabled {
                startWatcher()
            } else {
                stopWatcher()
            }
        }
    }

    /// Current framing state (updated by the watcher).
    var framingPresence: FramingPresence = FramingPresence(position: .noFace)

    private var watcherTask: Task<Void, Never>? = nil

    /// Global NSEvent monitor — only active while the screen is locked.
    /// Set up in startInputMonitor(), torn down in stopInputMonitor().
    private var inputMonitor: Any? = nil

    var showInDock: Bool {
        didSet {
            if !showInDock && !showInMenuBar { showInMenuBar = true }  // safety: never hide both
            UserDefaults.standard.set(showInDock, forKey: Self.dockPrefKey)
            applyActivationPolicy()
        }
    }

    var showInMenuBar: Bool {
        didSet {
            if !showInDock && !showInMenuBar { showInDock = true }  // safety: never hide both
            UserDefaults.standard.set(showInMenuBar, forKey: Self.menuBarPrefKey)
        }
    }

    // Currently-running task (for cancellation)
    private(set) var currentTask: Task<Void, Never>? = nil

    // Tunable constants — tuned for fast unlock (~1-2 second target).
    let pollIntervalNS: UInt64 = 60_000_000  // 60 ms (~17 fps scan)
    let verifyScanTimeoutSeconds: Double = 15

    /// Frames captured during the first N ms after camera start are excluded
    /// from the best-of-N embedding average. Cold-camera AE/AWB is still
    /// converging in this window, so the embeddings from those frames don't
    /// match the enrollment distribution and would drag similarity down.
    private let scanWarmupDiscardMS: Double = 800

    /// Frames outside this pose envelope are excluded from the best-of-N
    /// embedding average. Off-angle frames (large yaw or roll) produce
    /// embeddings that don't correspond to the head-on views that dominate
    /// real usage — including them shifts the running average toward extreme
    /// enrollment poses and lowers centroid similarity for typical live views.
    /// 0.35 rad ≈ 20°, well beyond normal look-at-screen head motion but tight
    /// enough to filter out clearly-turned frames.
    private let poseAcceptableYawMax: Float = 0.35
    private let poseAcceptableRollMax: Float = 0.35

    init() {
        // Restore icon-placement preferences (default: hidden from dock, shown in menu bar).
        self.showInDock = UserDefaults.standard.bool(forKey: Self.dockPrefKey)
        self.showInMenuBar = UserDefaults.standard.object(forKey: Self.menuBarPrefKey) as? Bool ?? true
        self.autoFramingEnabled = UserDefaults.standard.bool(forKey: Self.autoFramingPrefKey)

        // Restore auto-unlock & detection settings.
        self.autoUnlockEnabled = UserDefaults.standard.bool(forKey: Self.autoUnlockEnabledPrefKey)
        self.autoUnlockStartDelaySeconds = (UserDefaults.standard.object(forKey: Self.autoUnlockDelayPrefKey) as? Double) ?? 4.0
        self.matchThreshold = (UserDefaults.standard.object(forKey: Self.matchThresholdPrefKey) as? Double).map(Float.init) ?? FaceEnrollmentService.defaultMatchThreshold
        self.injectionDelaySeconds = (UserDefaults.standard.object(forKey: Self.injectionDelayPrefKey) as? Double) ?? 0.0

        // Wire the wake-event callback to fire even when no SwiftUI view is alive.
        lockMonitor.onScreensWoke = { [weak self] in
            // Hop to MainActor — LockMonitor invokes on the main queue but Swift concurrency
            // doesn't infer actor isolation across notification callbacks.
            Task { @MainActor [weak self] in
                self?.handleScreensWoke()
            }
        }

        // When the screen locks, start listening for any user input (key / click)
        // so we can also trigger unlock for the lock-without-display-sleep case.
        // We deliberately tear the monitor down on unlock so we're not snooping
        // keystrokes during normal use.
        lockMonitor.onScreensLocked = { [weak self] in
            Task { @MainActor [weak self] in
                self?.startInputMonitor()
            }
        }
        lockMonitor.onScreensUnlocked = { [weak self] in
            Task { @MainActor [weak self] in
                // If the user manually unlocked while we had a scan / unlock
                // task in flight, cancel it. Otherwise the scan could finish
                // and inject the password into whatever window is frontmost
                // in the now-unlocked session.
                self?.currentTask?.cancel()
                self?.stopInputMonitor()
            }
        }

        // Anti-debug: refuse debugger attachment in release builds. Guarded because
        // it would break Xcode debugging in DEBUG.
        #if !DEBUG
        Self.denyDebuggerAttachment()
        #endif

        // Apply the initial activation policy after init completes so NSApp is ready.
        Task { @MainActor [weak self] in
            self?.applyActivationPolicy()
            if self?.autoFramingEnabled == true {
                self?.startWatcher()
            }
            // Auto-attempt session unlock if a key exists in the Keychain. Fires Touch ID
            // prompt at launch; user can dismiss (session stays locked) or accept.
            // We check `hasSessionKey` rather than `hasStoredPassword` because the key
            // can exist independent of the password blob (e.g. after enrollment before
            // the user has set their Mac password).
            if PasswordVault.hasSessionKey(), self?.isSessionUnlocked == false {
                await self?.unlockSession()
            }
        }
    }

    // MARK: - Anti-debug

    #if !DEBUG
    /// PT_DENY_ATTACH — blocks casual lldb `-p <pid>` attachment. Not a defense against
    /// a determined attacker with root or SIP disabled, but blocks the realistic
    /// "attach debugger, dump memory, extract password" scenario.
    private nonisolated static func denyDebuggerAttachment() {
        typealias PtraceFn = @convention(c) (CInt, pid_t, UnsafeMutablePointer<CChar>?, CInt) -> CInt
        guard let handle = dlopen(nil, RTLD_NOW),
              let sym = dlsym(handle, "ptrace") else { return }
        let ptrace = unsafeBitCast(sym, to: PtraceFn.self)
        _ = ptrace(31, 0, nil, 0)  // PT_DENY_ATTACH == 31
    }
    #endif

    // MARK: - Framing watcher

    func startWatcher() {
        guard watcherTask == nil else { return }
        watcherTask = Task { @MainActor [weak self] in
            await self?.runWatcher()
        }
    }

    func stopWatcher() {
        watcherTask?.cancel()
        watcherTask = nil
        framingPresence = FramingPresence(position: .noFace)
    }

    private func runWatcher() async {
        var consecutiveGood = 0
        let requiredGoodFrames = 3  // ~0.45s at 150ms polling
        let watcherPollIntervalNS: UInt64 = 150_000_000

        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: watcherPollIntervalNS)
            if Task.isCancelled { break }

            // Skip while a scan / unlock is already running.
            if isWorking || isVerifying {
                consecutiveGood = 0
                continue
            }

            // Camera may be off (e.g. window closed). Just wait.
            guard camera.isRunning, let frame = camera.currentFrame() else {
                if framingPresence.position != .noFace {
                    framingPresence = FramingPresence(position: .noFace)
                }
                consecutiveGood = 0
                continue
            }

            do {
                let bbox = try service.detectFacePosition(in: frame)
                let presence = checkFraming(bbox: bbox)
                if presence != framingPresence {
                    framingPresence = presence
                }

                if presence.position == .good {
                    consecutiveGood += 1
                    if consecutiveGood >= requiredGoodFrames {
                        consecutiveGood = 0
                        // Trigger the scan — full unlock if everything is set up,
                        // else just verify (so the user can test enrollment quickly).
                        if canAttemptUnlock {
                            await runUnlockFlow(trigger: .autoOnFraming)
                        } else if FaceEnrollmentService.hasEnrolledFace() {
                            // Fall back to verify-only when password/accessibility isn't set up.
                            await verifyOnly()
                        }
                    }
                } else {
                    consecutiveGood = 0
                }
            } catch {
                if framingPresence.position != .noFace {
                    framingPresence = FramingPresence(position: .noFace)
                }
                consecutiveGood = 0
            }
        }
        watcherTask = nil
    }

    private func checkFraming(bbox: CGRect) -> FramingPresence {
        let centerX = bbox.midX
        let centerY = bbox.midY
        let size = bbox.width  // face bbox tends toward square; width is a fine proxy

        if abs(centerX - 0.5) > 0.15 || abs(centerY - 0.5) > 0.18 {
            return FramingPresence(position: .offCenter)
        }
        // size < 0.13 ≈ face is farther than ~70 cm; auto-framing prompts "move closer".
        // Otherwise anywhere from ~30 cm to ~70 cm is considered good positioning.
        if size < 0.13 {
            return FramingPresence(position: .tooSmall)
        }
        if size > 0.50 {
            return FramingPresence(position: .tooLarge)
        }
        return FramingPresence(position: .good)
    }

    private func applyActivationPolicy() {
        let policy: NSApplication.ActivationPolicy = showInDock ? .regular : .accessory
        NSApp.setActivationPolicy(policy)
    }

    // MARK: - Public computed state

    var canAttemptUnlock: Bool {
        FaceEnrollmentService.hasEnrolledFace()
        && hasStoredPassword
        && accessibilityGranted
        && service.isModelReady
        && isSessionUnlocked
    }

    var unlockReadinessHint: String {
        var missing: [String] = []
        if !FaceEnrollmentService.hasEnrolledFace() { missing.append("face enrollment") }
        if !hasStoredPassword { missing.append("Mac password") }
        if !accessibilityGranted { missing.append("Accessibility permission") }
        if !service.isModelReady { missing.append("FaceEmbedding model") }
        if !isSessionUnlocked && hasStoredPassword { missing.append("session unlock (Touch ID)") }
        return missing.isEmpty
            ? "Ready to unlock"
            : "Missing: " + missing.joined(separator: ", ")
    }

    func refreshSetupState() {
        hasStoredPassword = PasswordVault.hasStoredPassword()
        accessibilityGranted = KeystrokeInjector.isAccessibilityTrusted()
        isSessionUnlocked = PasswordVault.isSessionUnlocked
    }

    // MARK: - Session unlock (Touch ID once per app launch)

    /// Prompts Touch ID / device password to unwrap the session key into memory.
    /// After success, `readPassword()` (used inside the unlock flow) can run silently.
    /// Called automatically once at launch when a stored password exists.
    func unlockSession(reason: String = "Authenticate to enable FaceUnlock for this session") async {
        do {
            try await Task.detached(priority: .userInitiated) {
                try PasswordVault.unlockSession(reason: reason)
            }.value
            isSessionUnlocked = true
            sessionUnlockError = nil
        } catch {
            isSessionUnlocked = false
            if let e = error as? PasswordVaultError, case .userCancelled = e {
                sessionUnlockError = "Session unlock cancelled. Auto-unlock won't work until you authenticate."
            } else {
                sessionUnlockError = "Session unlock failed: \(error.localizedDescription)"
            }
        }
    }

    func lockSession() {
        PasswordVault.lockSession()
        isSessionUnlocked = false
    }

    /// Called by any UI action that's about to save/encrypt/decrypt encrypted data.
    ///
    /// - If the session key is already cached in memory → returns `true` immediately.
    /// - If a key exists in the Keychain but hasn't been unwrapped this session → prompts
    ///   Touch ID and unwraps it. Returns `true` on success, `false` if the user cancelled.
    /// - If no key exists yet in the Keychain (first-time user) → returns `true`. The
    ///   next save operation will silently create a fresh key.
    func ensureSessionUnlocked(reason: String = "Authenticate to enable FaceUnlock") async -> Bool {
        if isSessionUnlocked { return true }
        if PasswordVault.hasSessionKey() {
            await unlockSession(reason: reason)
            return isSessionUnlocked
        }
        // No key exists yet — a save will create one silently.
        return true
    }

    // MARK: - Camera settling

    /// Wait for the camera to produce stable frames after a fresh start.
    ///
    /// A fixed sleep (previously 800ms) is insufficient for a cold camera
    /// that macOS has powered down during hours of display sleep: auto-exposure
    /// and auto-white-balance are still converging past 800ms, so the first
    /// frames captured are systematically darker/brighter than enrollment
    /// frames. That drops embedding cosine similarity by 0.1–0.2 for the
    /// same face — enough to fail verification at threshold 0.85.
    ///
    /// This routine waits for:
    ///   1. The first frame to arrive (bounded at 2s).
    ///   2. An additional ~1s for AE/AWB convergence.
    ///
    /// Warm cameras (e.g. framing watcher already running) skip this via the
    /// `weStartedCamera` guard at the call site.
    private func waitForCameraSettled() async {
        let firstFrameDeadline = Date().addingTimeInterval(2.0)
        while camera.currentFrame() == nil {
            if Date() > firstFrameDeadline { return }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        // AE/AWB convergence budget on top of first-frame arrival.
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }

    // MARK: - Wake handling

    private func handleScreensWoke() {
        scheduleAutoUnlock(trigger: .autoOnWake)
    }

    private func handleUserInputWhileLocked() {
        scheduleAutoUnlock(trigger: .autoOnUserInput)
    }

    /// Shared scheduler for the wake / input triggers. Cancels any previously-pending
    /// auto-unlock and starts a fresh delayed task, gated by the user's settings.
    private func scheduleAutoUnlock(trigger: UnlockTrigger) {
        guard lockMonitor.isScreenLocked,
              autoUnlockEnabled,
              !isWorking,
              canAttemptUnlock else { return }
        currentTask?.cancel()
        let delayNS = UInt64(max(0, autoUnlockStartDelaySeconds) * 1_000_000_000)
        let task = Task { @MainActor in
            if delayNS > 0 {
                try? await Task.sleep(nanoseconds: delayNS)
            }
            guard !Task.isCancelled, lockMonitor.isScreenLocked else { return }
            await runUnlockFlow(trigger: trigger)
        }
        currentTask = task
    }

    // MARK: - Input monitor (only active while screen is locked)

    private func startInputMonitor() {
        guard inputMonitor == nil else { return }
        // Virtual key codes — Space / Return / Numpad Enter.
        let triggerKeyCodes: Set<UInt16> = [
            0x31,  // kVK_Space
            0x24,  // kVK_Return
            0x4C   // kVK_ANSI_KeypadEnter
        ]
        inputMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard triggerKeyCodes.contains(event.keyCode) else { return }
            Task { @MainActor [weak self] in
                self?.handleUserInputWhileLocked()
            }
        }
    }

    private func stopInputMonitor() {
        if let m = inputMonitor {
            NSEvent.removeMonitor(m)
        }
        inputMonitor = nil
    }

    // MARK: - Public actions

    func startVerifyOnly() {
        currentTask?.cancel()
        let task = Task { @MainActor in
            await verifyOnly()
        }
        currentTask = task
    }

    func cancelCurrentTask() {
        currentTask?.cancel()
        currentTask = nil
    }

    func resetThreshold() {
        matchThreshold = FaceEnrollmentService.defaultMatchThreshold
    }

    // MARK: - Verify only (no password injection)

    private func verifyOnly() async {
        isWorking = true
        isVerifying = true
        status = .idle
        liveAnalysis = nil
        liveSimilarity = nil
        liveError = nil
        liveLivenessState = nil

        let weStartedCamera = !camera.isRunning
        if weStartedCamera {
            await camera.start()
            await waitForCameraSettled()
        }

        defer {
            isWorking = false
            isVerifying = false
            liveAnalysis = nil
            liveSimilarity = nil
            liveError = nil
            liveLivenessState = nil
            currentTask = nil
            if weStartedCamera { camera.stop() }
        }

        do {
            let outcome = try await scanForMatch(timeoutSeconds: verifyScanTimeoutSeconds)
            switch outcome {
            case .matched(let result):
                status = .verifiedAndLive(result)
            case .noMatchInTime(let lastResult):
                status = .noMatch(lastResult)
            case .noFaceFound:
                status = .failure("No face detected during scan. Move into the camera's view and try again.")
            }
        } catch is CancellationError {
            status = .cancelled
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    // MARK: - Full unlock flow (scan + password + inject)

    func runUnlockFlow(trigger: UnlockTrigger) async {
        guard canAttemptUnlock else {
            status = .failure(unlockReadinessHint)
            return
        }

        isWorking = true
        isVerifying = true
        status = .idle
        liveAnalysis = nil
        liveSimilarity = nil
        liveError = nil
        liveLivenessState = nil

        let weStartedCamera = !camera.isRunning
        if weStartedCamera {
            await camera.start()
            await waitForCameraSettled()
        }

        defer {
            isWorking = false
            isVerifying = false
            liveAnalysis = nil
            liveSimilarity = nil
            liveError = nil
            liveLivenessState = nil
            currentTask = nil
            if weStartedCamera { camera.stop() }
        }

        do {
            let outcome = try await scanForMatch(timeoutSeconds: verifyScanTimeoutSeconds)
            switch outcome {
            case .noFaceFound:
                status = .failure("No face detected for unlock.")
                return
            case .noMatchInTime(let r):
                status = .noMatch(r)
                return
            case .matched:
                isVerifying = false
                liveSimilarity = nil

                // Authoritative pre-injection lock check. Two failure modes
                // this closes off:
                //
                //   1. The user manually unlocked mid-scan (their screen is
                //      now unlocked, arbitrary apps have focus). We must not
                //      type the password into whatever window is frontmost.
                //
                //   2. A malicious user-session process spoofed the
                //      `com.apple.screenIsLocked` notification to trick us
                //      into thinking the screen is locked when it isn't. The
                //      CGSession dictionary is authoritative and can't be
                //      spoofed by unprivileged code.
                //
                // Cross-check both the cached notification-derived flag AND
                // the live CGSession state. Refuse to inject if either
                // reports "not locked".
                guard lockMonitor.isScreenLocked,
                      LockMonitor.isScreenActuallyLocked() else {
                    status = .cancelled
                    return
                }

                let delaySeconds = max(0, injectionDelaySeconds)
                if delaySeconds > 0 {
                    status = .info(String(
                        format: "Verified. Typing password in %.1fs — focus the password field…", delaySeconds
                    ))
                    try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                    // Re-check after the delay — the user might have unlocked
                    // manually during it (or the injection-delay setting is
                    // being abused to widen the attack window).
                    guard lockMonitor.isScreenLocked,
                          LockMonitor.isScreenActuallyLocked() else {
                        status = .cancelled
                        return
                    }
                }

                // Read + inject + zero the plaintext, all inside one detached task.
                // The `Data` variable is unique to this closure — `defer` zeros bytes
                // before dealloc so the plaintext window is minimal.
                try await Task.detached(priority: .userInitiated) {
                    var passwordBytes = try PasswordVault.readPassword()
                    defer { passwordBytes.resetBytes(in: 0..<passwordBytes.count) }
                    try KeystrokeInjector.typeAndReturn(passwordBytes)
                }.value

                let triggerName: String
                switch trigger {
                case .autoOnWake: triggerName = "auto on wake"
                case .autoOnFraming: triggerName = "auto on framing"
                case .autoOnUserInput: triggerName = "auto on user input"
                }
                status = .info("Unlock complete (\(triggerName)): password typed + Return.")
            }
        } catch is CancellationError {
            status = .cancelled
        } catch {
            status = .failure(error.localizedDescription)
        }
    }

    // MARK: - Scan loop with movement-based liveness

    func scanForMatch(timeoutSeconds: Double) async throws -> ScanOutcome {
        let scanStart = Date()
        let deadline = scanStart.addingTimeInterval(timeoutSeconds)
        var bestResult: VerificationResult? = nil           // best by centroid — for noMatch diagnostics
        var bestMatchResult: VerificationResult? = nil      // best frame that actually cleared the threshold
        var yawHistory: [Float] = []
        var rollHistory: [Float] = []
        var embeddingWindow: [[Float]] = []                 // rolling window for best-of-N averaging
        // Tuned for fast unlock — ~0.4s of subtle natural movement is enough.
        // A static photo still won't accumulate any yaw/roll variance.
        let windowSize = 12
        let minSamples = 6
        let movementThreshold: Float = 0.013  // radians ≈ 0.75°
        let embeddingWindowSize = 15          // best-of-N averaging window — larger = more noise cancellation across cold-camera / variable-lighting jitter (√N scaling)
        let warmupDiscardSeconds = scanWarmupDiscardMS / 1000.0

        while Date() < deadline {
            if Task.isCancelled { throw CancellationError() }
            try? await Task.sleep(nanoseconds: pollIntervalNS)
            guard let frame = camera.currentFrame() else { continue }

            do {
                let analysis = try service.analyzeFrame(frame, includeQuality: false)
                liveAnalysis = LiveAnalysis(
                    yaw: analysis.yaw,
                    roll: analysis.roll,
                    quality: analysis.quality,
                    faceWidth: analysis.face.boundingBox.width
                )
                liveError = nil

                yawHistory.append(analysis.yaw)
                rollHistory.append(analysis.roll)
                if yawHistory.count > windowSize {
                    yawHistory.removeFirst()
                    rollHistory.removeFirst()
                }

                // Two filters on which frames feed the best-of-N verification path:
                //
                //   1. Warmup discard — frames captured in the first ~800ms of the
                //      scan are face-detected + liveness-tracked but NOT used for
                //      verification. Cold-camera AE/AWB is still converging then;
                //      those embeddings don't match enrollment distribution.
                //
                //   2. Pose filter — off-angle frames (yaw or roll beyond the
                //      pose envelope) are excluded from the embedding window. They
                //      correspond to extreme-turn enrollment poses and shift the
                //      running average away from typical head-on live views,
                //      lowering centroid similarity.
                //
                // Both filters keep liveness ticking (yaw/roll history above), so
                // total scan latency is unaffected — we just don't count noisy or
                // off-pose frames when computing the match.
                let elapsedInScan = Date().timeIntervalSince(scanStart)
                let inWarmup = elapsedInScan < warmupDiscardSeconds
                let poseAcceptable = abs(analysis.yaw) < poseAcceptableYawMax
                                  && abs(analysis.roll) < poseAcceptableRollMax

                if !inWarmup && poseAcceptable {
                    // Best-of-N: accumulate up to N recent embeddings and verify against
                    // the mean (re-normalized). Averaging smooths out single-frame noise
                    // from motion blur, exposure jitter, and alignment micro-errors so
                    // false rejections on a single fluke frame no longer happen.
                    embeddingWindow.append(analysis.embedding)
                    if embeddingWindow.count > embeddingWindowSize {
                        embeddingWindow.removeFirst()
                    }
                    let liveEmbedding: [Float] = embeddingWindow.count >= 2
                        ? Self.averageEmbeddings(embeddingWindow)
                        : analysis.embedding

                    let result = try service.verify(currentEmbedding: liveEmbedding,
                                                    threshold: matchThreshold)
                    liveSimilarity = LiveSimilarity(centroid: result.centroidSimilarity,
                                                    maxIndividual: result.maxIndividualSimilarity,
                                                    threshold: result.threshold)

                    // Track best frame seen overall (for "best so far" reporting on timeout).
                    if bestResult == nil || result.centroidSimilarity > bestResult!.centroidSimilarity {
                        bestResult = result
                    }
                    // Separately remember the best frame that actually cleared the threshold.
                    if result.matched, (bestMatchResult == nil || result.centroidSimilarity > bestMatchResult!.centroidSimilarity) {
                        bestMatchResult = result
                    }
                }

                let yawRange = yawHistory.count >= 2
                    ? (yawHistory.max() ?? 0) - (yawHistory.min() ?? 0)
                    : 0
                let rollRange = rollHistory.count >= 2
                    ? (rollHistory.max() ?? 0) - (rollHistory.min() ?? 0)
                    : 0
                let livenessOK = yawHistory.count >= minSamples
                    && (yawRange > movementThreshold || rollRange > movementThreshold)

                liveLivenessState = LiveLiveness(
                    yawRange: yawRange,
                    rollRange: rollRange,
                    threshold: movementThreshold,
                    samplesCollected: yawHistory.count,
                    minSamples: minSamples,
                    isLive: livenessOK
                )

                // Match and liveness can each be satisfied at different frames within
                // the scan window — we return as soon as both have been seen at least once.
                if livenessOK, let matched = bestMatchResult {
                    return .matched(matched)
                }
            } catch {
                liveAnalysis = nil
                liveError = (error as? FaceEnrollmentError)?.errorDescription ?? error.localizedDescription
                continue
            }
        }

        if let r = bestResult { return .noMatchInTime(r) }
        return .noFaceFound
    }

    /// Element-wise mean of N embeddings, re-normalized to unit length.
    /// Standard technique for stabilizing face embeddings across consecutive frames.
    private static func averageEmbeddings(_ embeddings: [[Float]]) -> [Float] {
        guard let first = embeddings.first else { return [] }
        let dim = first.count
        var sum = [Float](repeating: 0, count: dim)
        for vec in embeddings {
            for i in 0..<dim { sum[i] += vec[i] }
        }
        let n = Float(embeddings.count)
        for i in 0..<dim { sum[i] /= n }
        return FaceEmbedder.l2Normalize(sum)
    }
}
