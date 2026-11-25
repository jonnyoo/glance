//
//  FaceVerifier.swift
//  glance
//
//  A short "is this the enrolled user?" check for App Lock: recognition plus liveness, kept apart from the lock-screen
//  scan so that flow stays untouched.
//

import Foundation
import CoreGraphics

@MainActor
final class FaceVerifier {
    enum Outcome: Equatable {
        case matched
        case notRecognized
        /// Nothing to compare against (session locked, nobody enrolled) or the camera couldn't start.
        case unavailable
    }

    private let camera: CameraManager
    private let pipeline: FaceRecognitionPipeline

    init(camera: CameraManager, pipeline: FaceRecognitionPipeline) {
        self.camera = camera
        self.pipeline = pipeline
    }

    func verify(timeout: TimeInterval = 5) async -> Outcome {
        guard SecureCredentialManager.isSessionUnlocked else { return .unavailable }
        let store = FaceEnrollmentStore.shared
        store.reloadIfUnlocked()
        let identities = store.activeIdentities
        guard !identities.isEmpty else { return .unavailable }

        await camera.start()
        defer { camera.stop() }
        guard camera.errorMessage == nil else { return .unavailable }

        let settings = GlanceSettings.shared
        let threshold = settings.matchThreshold
        let livenessEnabled = settings.livenessChecksEnabled
        let liveness = LivenessAnalyzer()
        liveness.modeProvider = { GlanceSettings.shared.livenessMode }
        var livenessConfirmed = !livenessEnabled
        var lastFrameID: UInt64?
        var lastFaceBox: CGRect?
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline, !Task.isCancelled {
            guard let frame = camera.currentFrame, frame.id != lastFrameID else {
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            lastFrameID = frame.id

            let pipeline = self.pipeline
            let previousBox = lastFaceBox
            let analysis = await Task.detached(priority: .userInitiated) { () -> (FaceRecognitionResult, LivenessFrame)? in
                guard let result = try? pipeline.recognize(in: frame.image, preferNear: previousBox) else { return nil }
                let faceCrop = CameraManager.renderCrop(from: frame, imageRect: result.face.boundingBox)
                return (result, LivenessFeatureExtractor.extract(from: result, frame: frame.image, faceCrop: faceCrop))
            }.value

            guard let (result, livenessFrame) = analysis else {
                lastFaceBox = nil
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            lastFaceBox = result.face.normalizedBoundingBox

            if livenessEnabled {
                switch liveness.observe(livenessFrame).decision {
                case .denied: return .notRecognized
                case .confirmed: livenessConfirmed = true
                case .pending: break
                }
            }

            let scored = pipeline.score(result.embedding, against: identities)
            if pipeline.bestMatch(in: scored, threshold: threshold) != nil, livenessConfirmed {
                return .matched
            }
        }
        return .notRecognized
    }
}
