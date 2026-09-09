//
//  SudoFaceAuthRunner.swift
//  glance
//
//  One-shot face match for sudo: camera + ArcFace + optional liveness.
//  Shows the notch/pill scan animation so sudo auth isn't invisible —
//  does not type passwords.
//

import Foundation

@MainActor
final class SudoFaceAuthRunner {
    private let camera = CameraManager()
    private let pipeline = FaceRecognitionPipeline()
    private let wrongFaceStreakThreshold = 6

    /// Runs until match+liveness, consistent wrong face, timeout, or cancel.
    func authenticate(timeout: TimeInterval) async -> SudoAuthProtocol.Result {
        guard SecureCredentialManager.isSessionUnlocked else {
            return .unavailable
        }
        FaceEnrollmentStore.shared.reloadIfUnlocked()
        let identities = FaceEnrollmentStore.shared.activeIdentities
        guard !identities.isEmpty else {
            return .unavailable
        }

        let showsUI = GlanceSettings.shared.showUnlockAnimation
        if showsUI {
            NotchOverlayController.shared.present()
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        var authResult: SudoAuthProtocol.Result = .deny
        defer {
            if showsUI {
                NotchOverlayController.shared.finish(success: authResult == .allow)
            }
        }

        await camera.start()
        defer { camera.stop() }

        guard camera.permission == .granted else {
            authResult = .unavailable
            return authResult
        }

        let warmupDeadline = Date().addingTimeInterval(1.5)
        while Date() < warmupDeadline, camera.currentFrame == nil {
            try? await Task.sleep(nanoseconds: 50_000_000)
            if Task.isCancelled {
                authResult = .deny
                return authResult
            }
        }

        let settings = GlanceSettings.shared
        let matchThreshold = settings.matchThreshold
        let livenessEnabled = settings.livenessChecksEnabled
        let livenessMode = settings.livenessMode
        let liveness = LivenessAnalyzer()
        liveness.modeProvider = { livenessMode }
        let deadline = Date().addingTimeInterval(timeout)

        var consecutiveWrongFaceFrames = 0
        var readyMatch: ScoredIdentity?
        var livenessConfirmed = !livenessEnabled
        var lastFaceBoundingBox: CGRect?
        var lastProcessedFrameID: UInt64?

        while Date() < deadline {
            if Task.isCancelled {
                authResult = .deny
                return authResult
            }
            guard SecureCredentialManager.isSessionUnlocked else {
                authResult = .unavailable
                return authResult
            }

            guard let frame = camera.currentFrame, frame.id != lastProcessedFrameID else {
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            lastProcessedFrameID = frame.id

            let pipeline = self.pipeline
            let previousBoundingBox = lastFaceBoundingBox
            let outcome = await Task.detached(priority: .userInitiated) { () -> (FaceRecognitionResult, LivenessFrame)? in
                guard let result = try? pipeline.recognize(in: frame.image, preferNear: previousBoundingBox) else {
                    return nil
                }
                let faceCrop = CameraManager.renderCrop(from: frame, imageRect: result.face.boundingBox)
                return (result, LivenessFeatureExtractor.extract(from: result, frame: frame.image, faceCrop: faceCrop))
            }.value

            guard let (result, livenessFrame) = outcome else {
                consecutiveWrongFaceFrames = 0
                lastFaceBoundingBox = nil
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            lastFaceBoundingBox = result.face.normalizedBoundingBox

            if livenessEnabled {
                let snapshot = liveness.observe(livenessFrame)
                switch snapshot.decision {
                case .denied:
                    authResult = .deny
                    return authResult
                case .confirmed:
                    livenessConfirmed = true
                case .pending:
                    break
                }
            }

            let scored = pipeline.score(result.embedding, against: identities)
            if let matched = pipeline.bestMatch(in: scored, threshold: matchThreshold) {
                consecutiveWrongFaceFrames = 0
                readyMatch = matched
            } else {
                readyMatch = nil
                consecutiveWrongFaceFrames += 1
                if consecutiveWrongFaceFrames >= wrongFaceStreakThreshold {
                    authResult = .deny
                    return authResult
                }
            }

            if readyMatch != nil, livenessConfirmed {
                authResult = .allow
                return authResult
            }

            try? await Task.sleep(nanoseconds: 20_000_000)
        }

        authResult = .deny
        return authResult
    }
}
