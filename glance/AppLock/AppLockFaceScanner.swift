//
//  AppLockFaceScanner.swift
//  glance
//
//  One "is this the owner?" look through the camera, for App Lock. The same recognition + liveness gates as
//  `FaceUnlockCoordinator.observeScanWindow` — same threshold, same liveness settings, same enrolled identities — minus
//  everything that only makes sense on the lock screen (no password, no keystrokes, no notch-phase coupling).
//
//  Kept as its own loop rather than shared with the lock-screen path on purpose: that one types the Mac password and is
//  tuned around a locked screen, and a refactor to share ~60 lines isn't worth putting it at risk. If the gates there
//  change (wrong-face grace, liveness handling), mirror the change here.
//

import Foundation
import CoreGraphics

@MainActor
final class AppLockFaceScanner {
    enum Outcome: Equatable {
        case matched
        /// A face was there for the whole grace period and never matched.
        case wrongFace
        /// A liveness deny cue fired — a photo or a screen, as far as the checks can tell.
        case spoofSuspected
        case noFace
        case cameraUnavailable
        /// `cancel()` or a newer `scan()` took over; the result means nothing and must be ignored.
        case superseded
    }

    /// Its own camera rather than `FaceUnlockCoordinator`'s, so a screen lock landing mid-scan can't have the two
    /// flows stopping each other's capture session.
    private let camera = CameraManager()
    /// Shared with the lock-screen path — a second pipeline would load a second copy of the ArcFace model.
    private let pipeline: FaceRecognitionPipeline

    /// Bumped by every `scan()` and `cancel()`. A scan that's been superseded bails without touching the camera, for
    /// the reason spelled out on `FaceUnlockCoordinator.runScanCycle`: its late `camera.stop()` would otherwise land
    /// on whichever scan replaced it.
    private var generation = 0

    /// Matches `FaceUnlockCoordinator.wrongFaceGraceDuration`: someone still turning toward the camera isn't a stranger.
    private let wrongFaceGraceDuration: Duration = .seconds(2)

    init(pipeline: FaceRecognitionPipeline) {
        self.pipeline = pipeline
    }

    /// Runs until a face matches (and liveness agrees), one is rejected, or the face-detection window elapses.
    func scan() async -> Outcome {
        generation &+= 1
        let generation = self.generation

        await camera.start()
        guard generation == self.generation else { return .superseded }
        guard camera.errorMessage == nil else {
            camera.stop()
            return .cameraUnavailable
        }

        let window = TimeInterval(GlanceSettings.shared.faceDetectionSeconds)
        let outcome = await observe(until: Date().addingTimeInterval(window), generation: generation)

        // A newer scan owns the camera now — leave it running.
        guard generation == self.generation else { return .superseded }
        camera.stop()
        return outcome
    }

    func cancel() {
        generation &+= 1
        camera.stop()
    }

    /// Recognition and liveness each latch independently, and the scan resolves the moment both have — see the
    /// lock-screen loop this mirrors for the reasoning behind each piece of state.
    private func observe(until deadline: Date, generation: Int) async -> Outcome {
        let settings = GlanceSettings.shared
        let matchThreshold = settings.matchThreshold
        let livenessEnabled = settings.livenessChecksEnabled
        let liveness = LivenessAnalyzer()
        liveness.modeProvider = { GlanceSettings.shared.livenessMode }

        var wrongFaceStartedAt: ContinuousClock.Instant?
        var hasMatch = false
        var livenessConfirmed = !livenessEnabled
        var lastFaceBoundingBox: CGRect?
        var lastProcessedFrameID: UInt64?

        while Date() < deadline, !Task.isCancelled, generation == self.generation {
            guard let frame = camera.currentFrame, frame.id != lastProcessedFrameID else {
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            lastProcessedFrameID = frame.id

            let pipeline = self.pipeline
            let previousBoundingBox = lastFaceBoundingBox
            let observation = await Task.detached(priority: .userInitiated) { () -> (FaceRecognitionResult, LivenessFrame)? in
                guard let result = try? pipeline.recognize(in: frame.image, preferNear: previousBoundingBox) else { return nil }
                let faceCrop = CameraManager.renderCrop(from: frame, imageRect: result.face.boundingBox)
                return (result, LivenessFeatureExtractor.extract(from: result, frame: frame.image, faceCrop: faceCrop))
            }.value

            guard let (result, livenessFrame) = observation else {
                wrongFaceStartedAt = nil
                lastFaceBoundingBox = nil
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            lastFaceBoundingBox = result.face.normalizedBoundingBox

            // Fed regardless of match, so liveness stays an independent gate; a deny overrides everything.
            if livenessEnabled {
                switch liveness.observe(livenessFrame).decision {
                case .denied:
                    return .spoofSuspected
                case .confirmed:
                    livenessConfirmed = true
                case .pending:
                    break
                }
            }

            // `activeIdentities`, not `identities`: a face switched off on the Face page must not open anything.
            let scored = pipeline.score(result.embedding, against: FaceEnrollmentStore.shared.activeIdentities)
            if pipeline.bestMatch(in: scored, threshold: matchThreshold) != nil {
                wrongFaceStartedAt = nil
                hasMatch = true
            } else {
                // Cleared on the first non-match, so a latched match can't be handed to whoever steps in next.
                hasMatch = false
                let startedAt = wrongFaceStartedAt ?? .now
                wrongFaceStartedAt = startedAt
                if ContinuousClock.now - startedAt >= wrongFaceGraceDuration {
                    return .wrongFace
                }
            }

            if hasMatch, livenessConfirmed {
                return .matched
            }

            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return .noFace
    }
}
