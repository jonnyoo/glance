//
//  DeviceBezelDetector.swift
//  glance
//
//  Looks for a device bezel (phone/tablet) around the face via
//  VNDetectRectanglesRequest; only ever produces positive evidence of
//  spoofing, never positive evidence of liveness.
//

import Vision
import CoreGraphics

struct DeviceBezelObservation {
    /// Device-sized rectangle holding the face's core this frame, same pixel space as `DetectedFace.boundingBox`.
    let rectangle: CGRect?
    /// Fraction of the face's bounding box area that falls inside `rectangle`.
    let faceOverlapFraction: CGFloat?

    nonisolated static let none = DeviceBezelObservation(rectangle: nil, faceOverlapFraction: nil)
}

nonisolated enum DeviceBezelDetector {
    /// A screen always shows the face's core, so a rectangle only counts as a device when it holds
    /// the face box inset by this fraction of its width and height per side: the eyes-nose-mouth
    /// band. Requiring the whole box let a close selfie zoomed past the screen edge through, since
    /// Vision's box then runs 15-25% past the screen on the cut side. A monitor or doorway the head
    /// is merely in front of crosses the face near its middle and misses the core.
    private static let faceCoreInset: CGFloat = 0.3

    /// Face area alone can't tell a room-scale window from a tablet: at the Far gate, or on a 4:3
    /// camera, a tablet held fully in frame passes 16x the face it shows. So a rectangle around the
    /// face is only written off as background when it is this large *and* fills the view as well, where
    /// a window around a far face and a tablet held flush to the lens look the same.
    private static let maximumFaceAreaRatio: CGFloat = 16
    /// Fraction of both frame dimensions a rectangle must span to count as filling the view. Vision
    /// reports a thick frame's inner edge, so a window flush with the view still lands ~5-7% in from
    /// each side. A tablet fully in frame only spans both when its shape matches the camera's and it
    /// sits nearly flush; with a clear margin on either axis it stays a device.
    private static let viewFillingSpan: CGFloat = 0.85

    /// First-pass estimates, not validated against real footage — tune here if false positives/negatives show up.
    private static func makeRequest() -> VNDetectRectanglesRequest {
        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = 0.6
        // Fraction of the image's smaller dimension, not of its area: ~54px on a 640x360 frame,
        // already below the smallest rectangle that could enclose a face the prominence gate accepts.
        request.minimumSize = 0.15
        request.maximumObservations = 3
        // Covers phone-in-portrait (0.35) through near-square tablet crop (1.0).
        request.minimumAspectRatio = 0.35
        request.maximumAspectRatio = 1.0
        // Generous so a phone held at a slight angle still registers.
        request.quadratureTolerance = 30

        return request
    }

    /// Synchronous and CPU-bound — call from a background task, same as `FaceDetector.detectFaces`.
    static func detect(in image: CGImage, faceBoundingBox: CGRect) -> DeviceBezelObservation {
        bestCandidate(
            among: rectangleCandidates(in: image), faceBoundingBox: faceBoundingBox,
            frameSize: CGSize(width: image.width, height: image.height)
        )
    }

    /// Every rectangle Vision found, in `DetectedFace.boundingBox` pixel space.
    static func rectangleCandidates(in image: CGImage) -> [CGRect] {
        let request = makeRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil, let results = request.results else { return [] }

        let imageSize = CGSize(width: image.width, height: image.height)
        return results.map { FaceDetector.convertToImageSpace($0.boundingBox, imageSize: imageSize) }
    }

    /// Kept apart from Vision so `tools/liveness_background_selftest.swift` can drive it with exact
    /// rectangles. Taking the largest rectangle anywhere let a monitor or doorway behind the head
    /// convict a live face, and let a bigger background rectangle hide a phone actually held up.
    static func bestCandidate(among candidates: [CGRect], faceBoundingBox: CGRect, frameSize: CGSize) -> DeviceBezelObservation {
        let faceArea = faceBoundingBox.width * faceBoundingBox.height
        guard faceArea > 0 else { return .none }

        func overlap(_ rect: CGRect) -> CGFloat {
            let intersection = rect.intersection(faceBoundingBox)
            return intersection.isNull ? 0 : (intersection.width * intersection.height) / faceArea
        }
        // An unknown frame size can't prove a rectangle fills the view, so nothing is written off.
        func isRoomScale(_ rect: CGRect) -> Bool {
            frameSize.width > 0 && frameSize.height > 0
                && rect.width * rect.height > faceArea * maximumFaceAreaRatio
                && rect.width >= frameSize.width * viewFillingSpan
                && rect.height >= frameSize.height * viewFillingSpan
        }
        let faceCore = faceBoundingBox.insetBy(
            dx: faceBoundingBox.width * faceCoreInset, dy: faceBoundingBox.height * faceCoreInset
        )
        let devices = candidates.filter { $0.contains(faceCore) && !isRoomScale($0) }

        guard let device = devices.max(by: { overlap($0) < overlap($1) }) else { return .none }
        return DeviceBezelObservation(rectangle: device, faceOverlapFraction: overlap(device))
    }
}
