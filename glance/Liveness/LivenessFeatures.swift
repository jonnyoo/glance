//
//  LivenessFeatures.swift
//  glance
//
//  The Vision-facing half of liveness: turns one `FaceRecognitionResult`
//  (plus the full camera frame it came from) into a `LivenessFrame`
//  (defined in LivenessScoring.swift, which has no Vision dependency) —
//  plain points and scalars, no Vision types — which is all
//  `LivenessScoring`/`LivenessAnalyzer` ever see. Keeping the Vision-facing
//  extraction isolated to this one file, separate from `LivenessFrame`'s
//  own declaration, is what lets the scoring math compile and run
//  standalone (see `tools/liveness_selftest.swift`) with no
//  `FaceRecognitionPipeline`/CoreML dependency chain to drag in.
//

import Vision
import CoreGraphics

nonisolated enum LivenessFeatureExtractor {
    /// Extracts a `LivenessFrame` from one recognition result. Never fails —
    /// a face with no landmarks still yields a frame (with `landmarks: []`),
    /// since pose/quality/bbox data alone is still worth having in the
    /// window; downstream signals that need landmarks just get zero
    /// confidence from it.
    ///
    /// - Parameter frame: the full camera frame `result` was recognized
    ///   from — not `result.alignedImage`, which is a tightly-cropped,
    ///   pose-normalized 112x112 warp with no room around the face to see
    ///   a device edge in. Needed for `DeviceBezelDetector`, which has to
    ///   look *around* the face, not just at it.
    static func extract(from result: FaceRecognitionResult, frame: CGImage, timestamp: Date = Date()) -> LivenessFrame {
        let face = result.face
        let deviceOverlap = DeviceBezelDetector.detect(in: frame, faceBoundingBox: face.boundingBox).faceOverlapFraction

        guard let landmarks = face.landmarks else {
            return LivenessFrame(
                timestamp: timestamp, landmarks: [], interocularDistance: nil,
                yaw: face.yaw, pitch: face.pitch, roll: face.roll,
                normalizedFaceWidth: face.normalizedBoundingBox.width,
                leftEyeAspectRatio: nil, rightEyeAspectRatio: nil,
                mouthOpeningRatio: nil, mouthWidthRatio: nil,
                noseOffsetRatio: nil,
                quality: face.quality, hasReliableLandmarks: false,
                deviceOverlapFraction: deviceOverlap
            )
        }

        let imageSize = face.imageSize
        let points = LandmarkGeometry.allPoints(from: landmarks, imageSize: imageSize)
        let interocular = LandmarkGeometry.interocularDistance(from: landmarks, imageSize: imageSize)
        let leftEAR = landmarks.leftEye.flatMap { LandmarkGeometry.eyeAspectRatio(of: $0, imageSize: imageSize) }
        let rightEAR = landmarks.rightEye.flatMap { LandmarkGeometry.eyeAspectRatio(of: $0, imageSize: imageSize) }

        let eyeLeft = LandmarkGeometry.eyeCenter(pupil: landmarks.leftPupil, eye: landmarks.leftEye, imageSize: imageSize)
        let eyeRight = LandmarkGeometry.eyeCenter(pupil: landmarks.rightPupil, eye: landmarks.rightEye, imageSize: imageSize)

        var mouthOpeningRatio: CGFloat?
        var mouthWidthRatio: CGFloat?
        if let eyeLeft, let eyeRight,
           let expression = LandmarkGeometry.mouthExpressionMetrics(
                innerLips: landmarks.innerLips,
                outerLips: landmarks.outerLips,
                leftEyeCenter: eyeLeft,
                rightEyeCenter: eyeRight,
                imageSize: imageSize
           ) {
            mouthOpeningRatio = expression.opening
            mouthWidthRatio = expression.width
        }

        var noseOffsetRatio: CGFloat?
        if let interocular, interocular > 0, let eyeLeft, let eyeRight,
           let nose = landmarks.nose, let noseCenter = LandmarkGeometry.centroid(of: nose, imageSize: imageSize) {
            let eyeMidX = (eyeLeft.x + eyeRight.x) / 2
            noseOffsetRatio = (noseCenter.x - eyeMidX) / interocular
        }

        return LivenessFrame(
            timestamp: timestamp,
            landmarks: points,
            interocularDistance: interocular,
            yaw: face.yaw, pitch: face.pitch, roll: face.roll,
            normalizedFaceWidth: face.normalizedBoundingBox.width,
            leftEyeAspectRatio: leftEAR, rightEyeAspectRatio: rightEAR,
            mouthOpeningRatio: mouthOpeningRatio, mouthWidthRatio: mouthWidthRatio,
            noseOffsetRatio: noseOffsetRatio,
            quality: face.quality,
            hasReliableLandmarks: result.alignmentTier == .fivePoint,
            deviceOverlapFraction: deviceOverlap
        )
    }
}
