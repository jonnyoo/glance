import Foundation
import CoreGraphics

nonisolated enum InfraredFaceAnalysisError: LocalizedError {
    case faceCount(Int)
    case tooSmall
    case alignment
    case imageConversion

    var errorDescription: String? {
        switch self {
        case .faceCount(let count):
            return count == 0 ? "No face found. Look at the camera and capture again."
                : "More than one face is visible. Capture with only the reference person in view."
        case .tooSmall: return "Move closer to the camera, then capture again."
        case .alignment: return "Could not locate all five face landmarks. Face the camera and try again."
        case .imageConversion: return "Could not prepare the infrared image for face comparison."
        }
    }
}

/// Serializes access to the model and its pixel-buffer pool. There is no fallback
/// to generic image feature prints, nor any reuse of RGB enrollment templates.
actor InfraredFaceAnalyzer {
    private var model: ArcFaceEmbedder?

    /// May run while USB capture is in flight. This only loads the model;
    /// it never produces or reuses identity evidence.
    func prepare() throws {
        try Task.checkCancellation()
        if model == nil { model = try ArcFaceEmbedder() }
        try Task.checkCancellation()
    }

    func sample(from image: CGImage, captureID: UUID) throws -> InfraredFaceSample {
        try Task.checkCancellation()
        let faces = try FaceDetector.detectFaces(in: image, includeQuality: false)
        guard faces.count == 1, let face = faces.first else {
            throw InfraredFaceAnalysisError.faceCount(faces.count)
        }
        guard face.normalizedBoundingBox.width >= 0.18 else { throw InfraredFaceAnalysisError.tooSmall }
        // The shared aligner uses premultiplied RGB contexts. Replicate the IR
        // luminance into RGB channels without changing its acquisition modality.
        guard let context = CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw InfraredFaceAnalysisError.imageConversion
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let rgb = context.makeImage(), let aligned = FaceAligner.align(face, from: rgb),
              aligned.tier == .fivePoint else { throw InfraredFaceAnalysisError.alignment }
        try Task.checkCancellation()
        try prepare()
        guard let model else { throw ArcFaceEmbedderError.modelNotFound }
        let embedding = try model.embedding(for: aligned.image)
        try Task.checkCancellation()
        return InfraredFaceSample(captureID: captureID,
            modelIdentifier: "brio-046d-085e-l8ir-five-point-v1/" + model.modelIdentifier,
            embedding: embedding)
    }
}
