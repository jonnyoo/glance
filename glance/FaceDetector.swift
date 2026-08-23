//
//  FaceDetector.swift
//  glance
//
//  Milestones B & C: find a face in a frame, then crop it out.
//  Vision reports face boxes normalized (0...1) with a bottom-left origin;
//  this file converts them into pixel-space, top-left-origin `CGRect`s that
//  match `CGImage` cropping conventions, and does the actual crop.
//

import Vision
import CoreGraphics

struct DetectedFace {
    /// Pixel-space bounding box, top-left origin — ready to crop with.
    let boundingBox: CGRect
    /// Vision's original normalized (0...1, bottom-left origin) box. Kept
    /// around because it's exactly the format `AVCaptureVideoPreviewLayer
    /// .layerRectConverted(fromMetadataOutputRect:)` expects for drawing an
    /// overlay on the live preview, without re-deriving it from pixel space.
    let normalizedBoundingBox: CGRect
    /// 0...1 confidence from Vision that this is a face, roughly indicating
    /// image quality/pose suitability for recognition. `nil` if the quality
    /// request didn't produce a result for this face.
    let quality: Float?
    /// Head rotation in radians, when Vision could estimate it (needs a
    /// fairly frontal, well-lit face). Yaw is left/right turn — 0 is facing
    /// the camera, positive/negative turn toward one side — and is what
    /// drives the guided-pose onboarding capture. Roll (tilt) and pitch
    /// (up/down) are exposed for completeness but unused today.
    let yaw: Float?
    let roll: Float?
    let pitch: Float?
    /// Facial landmarks (eyes, nose, mouth, etc.), when available. Feeds
    /// `FaceAligner` for canonical 112x112 alignment ahead of ArcFace.
    nonisolated let landmarks: VNFaceLandmarks2D?
    /// The source frame's pixel dimensions — `landmarks.pointsInImage(_:)`
    /// needs this to convert normalized landmark points into the same
    /// pixel space as `boundingBox`. Derivable from `boundingBox.width /
    /// normalizedBoundingBox.width`, but storing it directly means every
    /// caller doesn't need to know that.
    let imageSize: CGSize
}

/// Pure, synchronous, CPU-bound work — `nonisolated` so it can run on a
/// background task despite the project's default main-actor isolation.
nonisolated enum FaceDetector {
    /// Runs face-rectangle, capture-quality, and landmarks detection on a
    /// single frame. Synchronous and CPU-bound — call from a background task.
    static func detectFaces(in image: CGImage) throws -> [DetectedFace] {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        let rectanglesRequest = VNDetectFaceRectanglesRequest()
        try handler.perform([rectanglesRequest])
        let faceObservations = rectanglesRequest.results ?? []
        guard !faceObservations.isEmpty else { return [] }

        // Quality and landmarks are run *chained* to the rectangles results
        // (via `inputFaceObservations`) rather than as independent requests
        // re-detecting from scratch. That guarantees their results
        // correspond 1:1, in order, to `faceObservations` — the previous
        // approach joined quality back to rects via a `[CGRect: Float]`
        // dictionary keyed on exact-float boundingBox equality, which is
        // fragile (float equality) and silently drops entries on any
        // mismatch. Chaining removes the ambiguity at the source.
        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        let landmarksRequest = VNDetectFaceLandmarksRequest()
        qualityRequest.inputFaceObservations = faceObservations
        landmarksRequest.inputFaceObservations = faceObservations
        try handler.perform([qualityRequest, landmarksRequest])

        let qualityResults = qualityRequest.results ?? []
        let landmarkResults = landmarksRequest.results ?? []
        let imageSize = CGSize(width: image.width, height: image.height)

        return faceObservations.enumerated().map { index, observation in
            let pixelRect = convertToImageSpace(observation.boundingBox, imageSize: imageSize)
            return DetectedFace(
                boundingBox: pixelRect,
                normalizedBoundingBox: observation.boundingBox,
                quality: qualityResults.indices.contains(index) ? qualityResults[index].faceCaptureQuality : nil,
                yaw: observation.yaw?.floatValue,
                roll: observation.roll?.floatValue,
                pitch: observation.pitch?.floatValue,
                landmarks: landmarkResults.indices.contains(index) ? landmarkResults[index].landmarks : nil,
                imageSize: imageSize
            )
        }
    }

    /// Vision's normalized rect has origin at bottom-left; `CGImage.cropping`
    /// expects pixel coordinates with origin at top-left. This flips the Y axis.
    static func convertToImageSpace(_ normalizedRect: CGRect, imageSize: CGSize) -> CGRect {
        let x = normalizedRect.origin.x * imageSize.width
        let width = normalizedRect.width * imageSize.width
        let height = normalizedRect.height * imageSize.height
        let y = (1 - normalizedRect.origin.y) * imageSize.height - height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// Crops `face` out of `image`, padding slightly around the detected box
    /// so the embedder sees a bit of context beyond just eyes/nose/mouth.
    static func crop(_ face: DetectedFace, from image: CGImage, paddingFraction: CGFloat = 0.2) -> CGImage? {
        let imageBounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let padX = face.boundingBox.width * paddingFraction
        let padY = face.boundingBox.height * paddingFraction
        let padded = face.boundingBox.insetBy(dx: -padX, dy: -padY).intersection(imageBounds)
        guard !padded.isEmpty else { return nil }
        return image.cropping(to: padded)
    }
}
