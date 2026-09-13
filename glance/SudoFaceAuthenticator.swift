import Foundation

/// A password-free face check for a single local sudo request.
///
/// Face enrollment is intentionally still protected by Glance's existing
/// Touch-ID-gated session. If that session is locked, PAM falls through to
/// Apple's Touch ID/password modules instead of weakening enrollment storage.
@MainActor
final class SudoFaceAuthenticator {
    private let camera = CameraManager()
    private let pipeline = FaceRecognitionPipeline()
    private var isAuthenticating = false
    private var retryRequested = false

    func authenticate() async -> Bool {
        guard GlanceSettings.shared.isSudoAuthenticationEnabled else { return false }
        guard !isAuthenticating else { return false }

        // Never turn a sudo face request into a surprise Touch ID prompt.
        // The user unlocks Glance's protected session explicitly in Settings;
        // while it is locked, PAM continues to Apple's normal methods.
        guard SecureCredentialManager.isSessionUnlocked else { return false }
        if FaceEnrollmentStore.shared.isLocked {
            FaceEnrollmentStore.shared.reloadIfUnlocked()
        }

        guard !FaceEnrollmentStore.shared.isLocked,
              !FaceEnrollmentStore.shared.activeIdentities.isEmpty
        else { return false }

        isAuthenticating = true
        retryRequested = false
        let requestRetry: () -> Void = { [weak self] in
            guard let self else { return }
            self.retryRequested = true
        }
        let showsUI = GlanceSettings.shared.showUnlockAnimation
        if showsUI {
            NotchOverlayController.shared.present(onRetry: requestRetry)
        }
        defer {
            camera.stop()
            retryRequested = false
            isAuthenticating = false
        }

        var hasRetried = false
        while GlanceSettings.shared.isSudoAuthenticationEnabled, !Task.isCancelled {
            // Allow the one-shot overlay to enter its scanning phase before a
            // fast camera failure can ask it to display the failure state.
            await Task.yield()

            let succeeded = await scanOnce(
                timeout: TimeInterval(GlanceSettings.shared.faceDetectionSeconds)
            )
            camera.stop()
            if showsUI {
                NotchOverlayController.shared.finish(success: succeeded)
            }
            if succeeded { return true }

            // Like normal Face Unlock, a failed frame remains hoverable while
            // the failure animation is held. Auto retry waits out that same
            // hold so the next attempt starts as a visibly fresh scan.
            guard !hasRetried else { return false }
            if showsUI {
                let retryDeadline = ContinuousClock.now + NotchOverlayController.shared.failureHoldDuration
                while ContinuousClock.now < retryDeadline,
                      GlanceSettings.shared.isSudoAuthenticationEnabled,
                      !Task.isCancelled {
                    if retryRequested {
                        hasRetried = true
                        retryRequested = false
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }

            if hasRetried { continue }
            guard GlanceSettings.shared.autoRetryOnce,
                  GlanceSettings.shared.isSudoAuthenticationEnabled,
                  !Task.isCancelled
            else { return false }

            hasRetried = true
            if showsUI {
                NotchOverlayController.shared.present(onRetry: requestRetry)
            } else {
                try? await Task.sleep(for: .seconds(1))
            }
        }
        return false
    }

    private func scanOnce(timeout: TimeInterval) async -> Bool {
        await camera.start()
        guard camera.errorMessage == nil else { return false }

        let liveness = LivenessAnalyzer()
        liveness.modeProvider = { .heavy }
        let deadline = Date().addingTimeInterval(timeout)
        var lastFrameID: UInt64?
        var lastBoundingBox: CGRect?
        var readyMatch = false
        var live = false
        var wrongFaceFrames = 0

        while Date() < deadline, !Task.isCancelled {
            guard GlanceSettings.shared.isSudoAuthenticationEnabled else { return false }
            guard let frame = camera.currentFrame, frame.id != lastFrameID else {
                try? await Task.sleep(for: .milliseconds(20))
                continue
            }
            lastFrameID = frame.id

            let pipeline = self.pipeline
            let previousBoundingBox = lastBoundingBox
            let result = await Task.detached(priority: .userInitiated) { () -> (FaceRecognitionResult, LivenessFrame)? in
                guard let recognized = try? pipeline.recognize(in: frame.image, preferNear: previousBoundingBox) else {
                    return nil
                }
                let crop = CameraManager.renderCrop(from: frame, imageRect: recognized.face.boundingBox)
                return (recognized, LivenessFeatureExtractor.extract(from: recognized, frame: frame.image, faceCrop: crop))
            }.value

            guard let (recognized, livenessFrame) = result else {
                lastBoundingBox = nil
                continue
            }
            lastBoundingBox = recognized.face.normalizedBoundingBox

            let snapshot = liveness.observe(livenessFrame)
            switch snapshot.decision {
            case .denied:
                return false
            case .confirmed:
                live = true
            case .pending:
                break
            }

            let scores = pipeline.score(recognized.embedding, against: FaceEnrollmentStore.shared.activeIdentities)
            if pipeline.bestMatch(in: scores, threshold: GlanceSettings.shared.matchThreshold) != nil {
                readyMatch = true
                wrongFaceFrames = 0
            } else {
                readyMatch = false
                wrongFaceFrames += 1
                if wrongFaceFrames >= 12 { return false }
            }

            if readyMatch && live {
                return true
            }
        }
        return false
    }
}
