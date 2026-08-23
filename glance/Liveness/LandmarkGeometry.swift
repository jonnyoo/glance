//
//  LandmarkGeometry.swift
//  glance
//
//  Shared landmark math used by both `FaceAligner` (aligning a single frame
//  for embedding) and the liveness analyzer (comparing landmarks *across*
//  frames to tell a live face from a flat presentation). Everything here
//  operates in top-left/y-down pixel space, matching `DetectedFace
//  .boundingBox` — see `imagePoints(of:imageSize:)` for the origin flip
//  Vision's own coordinate space requires.
//
//  Moved out of `FaceAligner` (where these were `private static`) rather
//  than duplicated, so the two call sites can never drift apart.
//

import Vision
import CoreGraphics

/// Every landmark region this app reads from `VNFaceLandmarks2D`. Includes
/// several — `faceContour`, `medianLine`, `noseCrest`, the eyebrows,
/// `innerLips` — that `FaceAligner` never needed (5-point alignment only
/// uses eyes/nose/outerLips) but liveness does: the more regions sampled,
/// the better `LivenessScoring`'s residual-coherence check can tell
/// "several independent facial parts moved together, non-rigidly" apart
/// from "the whole rigid plane moved."
enum LandmarkRegion: String, CaseIterable, Hashable {
    case leftEye, rightEye
    case leftEyebrow, rightEyebrow
    case nose, noseCrest
    case outerLips, innerLips
    case faceContour, medianLine
}

/// One landmark point, tagged with where it came from. `indexInRegion` is
/// what lets two frames' points be paired up for cross-frame comparison —
/// Vision returns each region's points in a stable order for points that
/// are actually detected, but a region can be entirely absent on either
/// frame (see the correspondence handling in `LivenessFeatures`).
struct LandmarkPoint {
    let point: CGPoint
    let region: LandmarkRegion
    let indexInRegion: Int
}

/// Pure geometry — `nonisolated` so it's callable from the same background
/// tasks `FaceAligner`/`FaceDetector` already run on.
nonisolated enum LandmarkGeometry {
    /// Vision's `pointsInImage(imageSize:)` returns pixel-scale points in
    /// Vision's native bottom-left-origin, y-up convention (confirmed via
    /// the newer origin-aware `pointsInImageCoordinates(_:origin:)` API,
    /// whose default is `.lowerLeft`). Flipped here to top-left/y-down to
    /// match `DetectedFace.boundingBox`.
    static func imagePoints(of region: VNFaceLandmarkRegion2D, imageSize: CGSize) -> [CGPoint] {
        region.pointsInImage(imageSize: imageSize).map { CGPoint(x: $0.x, y: imageSize.height - $0.y) }
    }

    static func centroid(of region: VNFaceLandmarkRegion2D, imageSize: CGSize) -> CGPoint? {
        let points = imagePoints(of: region, imageSize: imageSize)
        guard !points.isEmpty else { return nil }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    /// Prefers the pupil landmark (a precise point) over the eye outline's
    /// centroid (an approximation from eyelid boundary points) when Vision
    /// provides one.
    static func eyeCenter(pupil: VNFaceLandmarkRegion2D?, eye: VNFaceLandmarkRegion2D?, imageSize: CGSize) -> CGPoint? {
        if let pupil, let center = centroid(of: pupil, imageSize: imageSize) { return center }
        if let eye { return centroid(of: eye, imageSize: imageSize) }
        return nil
    }

    /// Distance between the two eye centers — the normalization scale used
    /// throughout liveness scoring (residuals, nose offset, blink depth are
    /// all expressed as a fraction of this), so scores stay comparable
    /// regardless of how close the face is to the camera.
    static func interocularDistance(from landmarks: VNFaceLandmarks2D, imageSize: CGSize) -> CGFloat? {
        guard let left = eyeCenter(pupil: landmarks.leftPupil, eye: landmarks.leftEye, imageSize: imageSize),
              let right = eyeCenter(pupil: landmarks.rightPupil, eye: landmarks.rightEye, imageSize: imageSize)
        else { return nil }
        return hypot(left.x - right.x, left.y - right.y)
    }

    /// Height/width of a landmark region's bounding box — a cheap stand-in
    /// for the classic 6-point eye-aspect-ratio (Vision's eye outline point
    /// count isn't the fixed 6 that formula assumes). A blink collapses
    /// this toward 0; a fully open eye sits in a roughly stable band per
    /// person. Used only as supporting evidence — see `LivenessScoring`'s
    /// blink signal, which treats a *dip and recovery* as the event, not
    /// this raw ratio's absolute value.
    static func boundingBoxAspectRatio(of region: VNFaceLandmarkRegion2D, imageSize: CGSize) -> CGFloat? {
        let points = imagePoints(of: region, imageSize: imageSize)
        guard points.count >= 3, let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max()
        else { return nil }
        let width = maxX - minX
        guard width > 0 else { return nil }
        return (maxY - minY) / width
    }

    static func eyeAspectRatio(of eyeRegion: VNFaceLandmarkRegion2D, imageSize: CGSize) -> CGFloat? {
        boundingBoxAspectRatio(of: eyeRegion, imageSize: imageSize)
    }

    /// Mouth *shape* in a face-aligned frame, not "did the mouth region
    /// move in the image." Coordinates are rotated so the eye line is the
    /// x-axis and scaled by interocular distance, which cancels whole-head
    /// translation, roll, and lean-in. What's left:
    ///
    /// - `opening`: vertical extent of the inner lips (outer if inner is
    ///   missing) — grows when the mouth opens, shrinks when it closes.
    /// - `width`: horizontal extent of the outer lips — grows when the
    ///   mouth widens into a smile, shrinks when it relaxes.
    ///
    /// Small yaw still foreshortens width by ~cos(yaw), a few percent at
    /// typical pose, well under a real smile. See `LivenessScoring.mouthDynamics`.
    static func mouthExpressionMetrics(
        innerLips: VNFaceLandmarkRegion2D?,
        outerLips: VNFaceLandmarkRegion2D?,
        leftEyeCenter: CGPoint,
        rightEyeCenter: CGPoint,
        imageSize: CGSize
    ) -> (opening: CGFloat, width: CGFloat)? {
        guard let outerLips else { return nil }
        return mouthExpressionMetrics(
            outerLipPoints: imagePoints(of: outerLips, imageSize: imageSize),
            innerLipPoints: innerLips.map { imagePoints(of: $0, imageSize: imageSize) } ?? [],
            leftEyeCenter: leftEyeCenter,
            rightEyeCenter: rightEyeCenter
        )
    }

    static func mouthExpressionMetrics(
        outerLipPoints: [CGPoint],
        innerLipPoints: [CGPoint],
        leftEyeCenter: CGPoint,
        rightEyeCenter: CGPoint
    ) -> (opening: CGFloat, width: CGFloat)? {
        let iod = hypot(rightEyeCenter.x - leftEyeCenter.x, rightEyeCenter.y - leftEyeCenter.y)
        guard iod > 0, outerLipPoints.count >= 3 else { return nil }

        let axisX = (rightEyeCenter.x - leftEyeCenter.x) / iod
        let axisY = (rightEyeCenter.y - leftEyeCenter.y) / iod
        let origin = CGPoint(
            x: (leftEyeCenter.x + rightEyeCenter.x) / 2,
            y: (leftEyeCenter.y + rightEyeCenter.y) / 2
        )

        func aligned(_ point: CGPoint) -> CGPoint {
            let vx = point.x - origin.x
            let vy = point.y - origin.y
            return CGPoint(
                x: (vx * axisX + vy * axisY) / iod,
                y: (-vx * axisY + vy * axisX) / iod
            )
        }

        let outer = outerLipPoints.map(aligned)
        guard let minX = outer.map(\.x).min(), let maxX = outer.map(\.x).max() else { return nil }
        let width = maxX - minX

        let openingPoints = innerLipPoints.count >= 3 ? innerLipPoints.map(aligned) : outer
        guard let minY = openingPoints.map(\.y).min(), let maxY = openingPoints.map(\.y).max() else { return nil }
        let opening = maxY - minY

        return (opening, width)
    }

    /// The named region accessor on `VNFaceLandmarks2D` for each
    /// `LandmarkRegion` case.
    static func region(_ region: LandmarkRegion, of landmarks: VNFaceLandmarks2D) -> VNFaceLandmarkRegion2D? {
        switch region {
        case .leftEye: return landmarks.leftEye
        case .rightEye: return landmarks.rightEye
        case .leftEyebrow: return landmarks.leftEyebrow
        case .rightEyebrow: return landmarks.rightEyebrow
        case .nose: return landmarks.nose
        case .noseCrest: return landmarks.noseCrest
        case .outerLips: return landmarks.outerLips
        case .innerLips: return landmarks.innerLips
        case .faceContour: return landmarks.faceContour
        case .medianLine: return landmarks.medianLine
        }
    }

    /// Every point Vision detected across every region in `LandmarkRegion`,
    /// each tagged with its region and position within that region so a
    /// later frame's points can be matched back up to these — a region
    /// missing entirely on this frame just contributes nothing, rather than
    /// throwing off the indices of the regions that are present.
    static func allPoints(from landmarks: VNFaceLandmarks2D, imageSize: CGSize) -> [LandmarkPoint] {
        var result: [LandmarkPoint] = []
        for regionCase in LandmarkRegion.allCases {
            guard let vnRegion = region(regionCase, of: landmarks) else { continue }
            let points = imagePoints(of: vnRegion, imageSize: imageSize)
            for (index, point) in points.enumerated() {
                result.append(LandmarkPoint(point: point, region: regionCase, indexInRegion: index))
            }
        }
        return result
    }

    // MARK: - Similarity transform

    /// Closed-form least-squares similarity transform (rotation + uniform
    /// scale + translation) mapping `sourcePoints` onto `destinationPoints`,
    /// via the standard 2D Procrustes solution using complex-number
    /// arithmetic: treating each mean-centered point as p = x + iy, the
    /// optimal complex scalar z = scale * e^(i*theta) is
    ///     z = (sum of qk * conj(pk)) / (sum of |pk|^2)
    /// with translation recovered from the centroids afterward. No SVD
    /// needed for the 2D case.
    ///
    /// This is also exactly the model a flat presentation (print or
    /// screen) is limited to: rotation, uniform scale, translation. Any
    /// motion a real face makes that *isn't* explained by this transform is
    /// the non-rigid residual `LivenessScoring` measures.
    static func solveSimilarityTransform(from sourcePoints: [CGPoint], to destinationPoints: [CGPoint]) -> CGAffineTransform? {
        guard sourcePoints.count == destinationPoints.count, sourcePoints.count >= 2 else { return nil }

        let n = CGFloat(sourcePoints.count)
        let srcSum = sourcePoints.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        let srcMean = CGPoint(x: srcSum.x / n, y: srcSum.y / n)
        let dstSum = destinationPoints.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        let dstMean = CGPoint(x: dstSum.x / n, y: dstSum.y / n)

        var numeratorReal: CGFloat = 0
        var numeratorImag: CGFloat = 0
        var denominator: CGFloat = 0
        for i in 0..<sourcePoints.count {
            let p = CGPoint(x: sourcePoints[i].x - srcMean.x, y: sourcePoints[i].y - srcMean.y)
            let q = CGPoint(x: destinationPoints[i].x - dstMean.x, y: destinationPoints[i].y - dstMean.y)
            // q * conj(p) = (qx + i*qy)(px - i*py) = (qx*px + qy*py) + i(qy*px - qx*py)
            numeratorReal += q.x * p.x + q.y * p.y
            numeratorImag += q.y * p.x - q.x * p.y
            denominator += p.x * p.x + p.y * p.y
        }
        guard denominator > 0 else { return nil }

        // scale*cos(theta), scale*sin(theta)
        let sc = numeratorReal / denominator
        let ss = numeratorImag / denominator

        // dst = R * scale * (src - srcMean) + dstMean, expanded into
        // CGAffineTransform's convention: x' = a*x + c*y + tx, y' = b*x + d*y + ty
        let a = sc, b = ss, c = -ss, d = sc
        let tx = dstMean.x - (a * srcMean.x + c * srcMean.y)
        let ty = dstMean.y - (b * srcMean.x + d * srcMean.y)
        return CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }
}
