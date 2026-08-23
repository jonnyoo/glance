//
//  DeviceBezelDetector.swift
//  glance
//
//  A structurally different liveness signal from everything in
//  LivenessScoring.swift: instead of trying to detect non-rigid motion in
//  landmark residuals (which real-world testing showed doesn't separate
//  cleanly from Vision's own landmark-detection noise — see the commit
//  that added this file), this looks for direct evidence that the face is
//  being shown *on* something rectangular: a phone or tablet held up to
//  the camera. `VNDetectRectanglesRequest` is the same Vision request
//  document-scanner apps use to find a card/page edge — a phone or tablet
//  screen is exactly that kind of quadrilateral.
//
//  Deliberately conservative: this only ever produces *positive evidence
//  of spoofing* (a detected device-shaped rectangle substantially
//  containing the face), never positive evidence of liveness. Not finding
//  a rectangle proves nothing — tight framing, glare, or a dark bezel can
//  all hide it — so absence of a detection must never count toward "live."
//

import Vision
import CoreGraphics

struct DeviceBezelObservation {
    /// The largest device-plausible rectangle found this frame, in the
    /// same pixel space as `DetectedFace.boundingBox` (top-left origin).
    let rectangle: CGRect?
    /// Fraction of the recognized face's own bounding box area that falls
    /// inside `rectangle` — how much the face reads as "sitting inside a
    /// rectangular device," not just incidentally sharing the frame with
    /// some unrelated rectangular object (a laptop lid, a picture frame).
    let faceOverlapFraction: CGFloat?

    nonisolated static let none = DeviceBezelObservation(rectangle: nil, faceOverlapFraction: nil)
}

nonisolated enum DeviceBezelDetector {
    /// Tuned for "a phone or tablet screen filling a meaningful fraction
    /// of frame, held roughly toward the camera" — not for finding every
    /// rectangle in the scene. These are first-pass estimates, not
    /// validated against real footage; if this signal produces false
    /// positives (books, laptop lids, monitors behind the user) or false
    /// negatives (a phone framed too tight to show its edge), tune here.
    private static func makeRequest() -> VNDetectRectanglesRequest {
        let request = VNDetectRectanglesRequest()
        request.minimumConfidence = 0.6
        // Fraction of image AREA, not width/height — a phone held close
        // enough to present a face for unlock should cover a substantial
        // chunk of frame, well above incidental background rectangles.
        request.minimumSize = 0.15
        request.maximumObservations = 3
        // Common phone/tablet screen aspect ratios in either orientation —
        // deliberately broad (0.35 covers a tall phone in portrait; 1.0
        // covers a near-square tablet crop) rather than narrowly tuned to
        // one specific device.
        request.minimumAspectRatio = 0.35
        request.maximumAspectRatio = 1.0
        // Degrees of corner-angle tolerance from a perfect rectangle —
        // generous, so a hand-held phone at a slight angle to the camera
        // (not perfectly parallel) still registers as one.
        request.quadratureTolerance = 30

        return request
    }

    /// Synchronous and CPU-bound — call from a background task, same as
    /// `FaceDetector.detectFaces`. Deliberately uses its own
    /// `VNImageRequestHandler` rather than sharing one with face
    /// detection: a real architectural cost (a second image decode pass),
    /// accepted for the cleaner separation between "find a face" and "find
    /// a device" — revisit if this measurably affects scan frame rate.
    static func detect(in image: CGImage, faceBoundingBox: CGRect) -> DeviceBezelObservation {
        let request = makeRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil,
              let results = request.results, !results.isEmpty
        else { return .none }

        let imageSize = CGSize(width: image.width, height: image.height)
        let candidates = results.map { FaceDetector.convertToImageSpace($0.boundingBox, imageSize: imageSize) }
        // The largest candidate — the device itself, not some smaller
        // rectangular detail (an icon on its screen, a picture frame
        // behind it) that also happened to qualify.
        guard let largest = candidates.max(by: { $0.width * $0.height < $1.width * $1.height }) else {
            return .none
        }

        let faceArea = faceBoundingBox.width * faceBoundingBox.height
        guard faceArea > 0 else { return DeviceBezelObservation(rectangle: largest, faceOverlapFraction: nil) }
        let intersection = largest.intersection(faceBoundingBox)
        let overlap = (intersection.width * intersection.height) / faceArea
        return DeviceBezelObservation(rectangle: largest, faceOverlapFraction: overlap)
    }
}
