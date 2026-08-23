//
//  FaceAligner.swift
//  glance
//
//  ArcFace (like most modern face-embedding models) is trained on faces
//  warped into a canonical pose: eyes level, fixed inter-eye distance, nose
//  and mouth in fixed positions. Feeding it a loose bounding-box crop (what
//  FaceDetector.crop produces) throws away a large chunk of its accuracy —
//  this is not optional polish, it's part of the model's contract.
//
//  This solves the 2D similarity transform (rotation + uniform scale +
//  translation) that maps 5 detected landmark points onto the standard
//  ArcFace 112x112 template, then warps the source image through it.
//

import Vision
import CoreGraphics

struct AlignedFace {
    let image: CGImage   // 112x112, canonically aligned
    let tier: AlignmentTier
}

enum AlignmentTier: String {
    case fivePoint = "5-point"
    case twoPoint = "2-point (eyes only)"
    case paddedCrop = "padded crop (no alignment)"
}

nonisolated enum FaceAligner {
    static let outputSize = 112

    /// Standard ArcFace/InsightFace 112x112 template landmark positions —
    /// left eye, right eye, nose, left mouth corner, right mouth corner —
    /// in top-left-origin pixel coordinates of the *output* image. "Left"/
    /// "right" here mean on-screen left/right (as the image reads), not the
    /// subject's anatomical left/right — see the ordering fix in
    /// `fivePoints(from:imageSize:)` below.
    private static let referencePoints: [CGPoint] = [
        CGPoint(x: 38.2946, y: 51.6963),
        CGPoint(x: 73.5318, y: 51.5014),
        CGPoint(x: 56.0252, y: 71.7366),
        CGPoint(x: 41.5493, y: 92.3655),
        CGPoint(x: 70.7299, y: 92.2041),
    ]
    private static let eyeReferencePoints = Array(referencePoints[0...1])

    /// Best-effort alignment: 5-point landmarks, falling back to 2-point
    /// (eyes only), falling back to the existing padded bounding-box crop
    /// resized to 112x112. Returns nil only if there's no usable face
    /// geometry at all (crop failed against image bounds).
    static func align(_ face: DetectedFace, from image: CGImage) -> AlignedFace? {
        let imageSize = CGSize(width: image.width, height: image.height)

        if let landmarks = face.landmarks,
           let points = fivePoints(from: landmarks, imageSize: imageSize),
           let warped = warp(image, sourcePoints: points, destinationPoints: referencePoints) {
            return AlignedFace(image: warped, tier: .fivePoint)
        }

        if let landmarks = face.landmarks,
           let eyes = twoPoints(from: landmarks, imageSize: imageSize),
           let warped = warp(image, sourcePoints: eyes, destinationPoints: eyeReferencePoints) {
            return AlignedFace(image: warped, tier: .twoPoint)
        }

        guard let cropped = FaceDetector.crop(face, from: image),
              let resized = resize(cropped, to: outputSize) else { return nil }
        return AlignedFace(image: resized, tier: .paddedCrop)
    }

    // MARK: - Landmark extraction
    //
    // The point/centroid/eye-center/transform math this needs lives in
    // `LandmarkGeometry` — shared with the liveness analyzer, which does
    // the same cross-frame Procrustes fit for a different purpose.

    private static func fivePoints(from landmarks: VNFaceLandmarks2D, imageSize: CGSize) -> [CGPoint]? {
        guard let eyeA = LandmarkGeometry.eyeCenter(pupil: landmarks.leftPupil, eye: landmarks.leftEye, imageSize: imageSize),
              let eyeB = LandmarkGeometry.eyeCenter(pupil: landmarks.rightPupil, eye: landmarks.rightEye, imageSize: imageSize),
              let nose = landmarks.nose, let noseCenter = LandmarkGeometry.centroid(of: nose, imageSize: imageSize),
              let outerLips = landmarks.outerLips else { return nil }

        // The reference template orders points on-screen-left-to-right, but
        // Vision's `leftEye`/`rightEye` name the subject's *anatomical*
        // eyes — which face the camera, so the subject's right eye is the
        // one that appears on-screen-left. Sorting by x-coordinate instead
        // of trusting either label sidesteps that mismatch entirely.
        let imageLeftEye = eyeA.x <= eyeB.x ? eyeA : eyeB
        let imageRightEye = eyeA.x <= eyeB.x ? eyeB : eyeA

        let lipPoints = LandmarkGeometry.imagePoints(of: outerLips, imageSize: imageSize)
        guard let imageLeftMouth = lipPoints.min(by: { $0.x < $1.x }),
              let imageRightMouth = lipPoints.max(by: { $0.x < $1.x }) else { return nil }

        return [imageLeftEye, imageRightEye, noseCenter, imageLeftMouth, imageRightMouth]
    }

    private static func twoPoints(from landmarks: VNFaceLandmarks2D, imageSize: CGSize) -> [CGPoint]? {
        guard let eyeA = LandmarkGeometry.eyeCenter(pupil: landmarks.leftPupil, eye: landmarks.leftEye, imageSize: imageSize),
              let eyeB = LandmarkGeometry.eyeCenter(pupil: landmarks.rightPupil, eye: landmarks.rightEye, imageSize: imageSize) else { return nil }
        return eyeA.x <= eyeB.x ? [eyeA, eyeB] : [eyeB, eyeA]
    }

    // MARK: - Warp

    /// Renders `image` through the similarity transform solved above into a
    /// fresh 112x112 canvas. Both point sets are given (and the transform is
    /// solved) in top-left/y-down pixel space; CGContext natively works in
    /// bottom-left/y-up space, so points are flipped into that space before
    /// solving — `CGContext.draw(_:in:)` already handles a CGImage's
    /// top-down row order correctly on its own, so the image itself needs
    /// no separate flip.
    private static func warp(_ image: CGImage, sourcePoints: [CGPoint], destinationPoints: [CGPoint]) -> CGImage? {
        let imageHeight = CGFloat(image.height)
        let sourceFlipped = sourcePoints.map { CGPoint(x: $0.x, y: imageHeight - $0.y) }
        let destinationFlipped = destinationPoints.map { CGPoint(x: $0.x, y: CGFloat(outputSize) - $0.y) }

        guard let transform = LandmarkGeometry.solveSimilarityTransform(from: sourceFlipped, to: destinationFlipped) else { return nil }

        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: outputSize, height: outputSize,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        context.concatenate(transform)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))

        return context.makeImage()
    }

    private static func resize(_ image: CGImage, to size: Int) -> CGImage? {
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return context.makeImage()
    }
}
