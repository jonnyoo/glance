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
}

/// Pure, synchronous, CPU-bound work — `nonisolated` so it can run on a
/// background task despite the project's default main-actor isolation.
nonisolated enum FaceDetector {
    /// Runs face-rectangle + capture-quality detection on a single frame.
    /// Synchronous and CPU-bound — call from a background task.
    static func detectFaces(in image: CGImage) throws -> [DetectedFace] {
        let rectanglesRequest = VNDetectFaceRectanglesRequest()
        let qualityRequest = VNDetectFaceCaptureQualityRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([rectanglesRequest, qualityRequest])

        let imageSize = CGSize(width: image.width, height: image.height)

        let qualityByRect: [CGRect: Float] = Dictionary(
            uniqueKeysWithValues: (qualityRequest.results ?? []).map {
                ($0.boundingBox, $0.faceCaptureQuality ?? 0)
            }
        )

        return (rectanglesRequest.results ?? []).map { observation in
            let pixelRect = convertToImageSpace(observation.boundingBox, imageSize: imageSize)
            return DetectedFace(
                boundingBox: pixelRect,
                normalizedBoundingBox: observation.boundingBox,
                quality: qualityByRect[observation.boundingBox]
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
