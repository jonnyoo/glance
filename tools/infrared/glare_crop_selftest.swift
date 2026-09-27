// Synthetic pixels only. Uses the real native crop and glare extractor;
// never starts a camera or loads personal images.
import AVFoundation
import CoreImage

@MainActor enum CameraDeviceCatalog {
    static func resolvedDevice() -> AVCaptureDevice? { nil }
}

@main struct GlareCropSelfTest {
    @MainActor static func main() {
        let face = CGRect(x: 240, y: 160, width: 160, height: 160)
        func measure(highlight: CGRect) -> GlareSample {
            let context = CGContext(data: nil, width: 640, height: 480, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray: 0.4, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 480))
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(highlight)
            let image = context.makeImage()!
            let frame = CameraFrame(id: 1, capturedAt: .now, image: image, source: CIImage(cgImage: image),
                sourceSize: CGSize(width: image.width, height: image.height))
            let crop = CameraManager.renderCrop(from: frame, imageRect: face)!
            return GlareCueExtractor.extract(faceCrop: crop)!
        }
        func cue(_ sample: GlareSample) -> CueReading {
            LivenessCues.glossGlare(LivenessFrame(timestamp: Date(), landmarks: [], interocularDistance: nil,
                yaw: nil, leftEyeAspectRatio: nil, rightEyeAspectRatio: nil, noseOffsetRatio: nil,
                hasReliableLandmarks: true, deviceOverlapFraction: nil, glare: sample))
        }
        // Previously included by the 15% margin, despite being outside the face.
        let background = measure(highlight: CGRect(x: 220, y: 180, width: 20, height: 80))
        precondition(background.specularFraction == 0 && cue(background).level == 0,
            "Bright background must not be treated as facial glare")
        let facial = measure(highlight: CGRect(x: 260, y: 180, width: 20, height: 80))
        precondition(cue(facial).confidence > 0 && cue(facial).level >= LivenessTuning.default.glossLevel,
            "The same highlight inside the face must still trigger the unchanged glare gate")
        print("Glare crop regression passed: outside-face reflection excluded; in-face glare still rejected at the unchanged threshold.")
    }
}
