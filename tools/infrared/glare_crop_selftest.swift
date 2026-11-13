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
        // A rectangular detector box still contains wall beside the temples
        // and below the jaw. Synthetic landmarks describe the actual outline.
        let outline = [CGPoint(x: 28, y: 64), CGPoint(x: 20, y: 100), CGPoint(x: 36, y: 150),
            CGPoint(x: 64, y: 182), CGPoint(x: 100, y: 196), CGPoint(x: 140, y: 182),
            CGPoint(x: 172, y: 140), CGPoint(x: 184, y: 96), CGPoint(x: 172, y: 64)]
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 200)
        let region = GlareFaceRegion.polygon(contour: outline, faceBounds: bounds, imageSize: bounds.size)!
        let reversed = GlareFaceRegion.polygon(contour: outline.reversed(), faceBounds: bounds, imageSize: bounds.size)!
        precondition(region == reversed)
        func croppedHighlight(_ highlight: CGRect, region: [CGPoint]?) -> GlareSample {
            let context = CGContext(data: nil, width: 200, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(gray: 0.4, alpha: 1)); context.fill(bounds)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(highlight)
            return GlareCueExtractor.extract(faceCrop: context.makeImage()!, faceRegion: region)!
        }
        // CGContext drawing coordinates are bottom-left; the outline is top-left.
        for highlight in [CGRect(x: 0, y: 0, width: 22, height: 50), CGRect(x: 194, y: 130, width: 6, height: 70)] {
            precondition(croppedHighlight(highlight, region: nil).specularFraction > 0)
            precondition(croppedHighlight(highlight, region: region).specularFraction == 0,
                "Background within the rectangle but outside the facial outline must be excluded")
        }
        for highlight in [CGRect(x: 80, y: 170, width: 25, height: 25), // forehead
                          CGRect(x: 55, y: 75, width: 25, height: 25), // cheek
                          CGRect(x: 88, y: 15, width: 25, height: 25)] { // chin
            let original = croppedHighlight(highlight, region: nil)
            let masked = croppedHighlight(highlight, region: region)
            precondition(masked.specularFraction >= original.specularFraction)
            precondition(cue(masked).level >= cue(original).level && cue(masked).level >= LivenessTuning.default.glossLevel,
                "Forehead, cheek and chin glare must remain at least as strong at the unchanged rejection threshold")
        }
        let degenerate = Array(repeating: CGPoint(x: 0.5, y: 0.5), count: 5)
        precondition(GlareCueExtractor.regionMask(degenerate, width: 200, height: 200) == nil)
        precondition(GlareCueExtractor.regionMask([CGPoint(x: CGFloat.nan, y: 0)] + Array(region.dropFirst()), width: 200, height: 200) == nil)
        precondition(GlareFaceRegion.polygon(contour: [], faceBounds: bounds, imageSize: bounds.size) == nil)
        let bright = CGRect(x: 80, y: 80, width: 30, height: 30)
        precondition(croppedHighlight(bright, region: degenerate) == croppedHighlight(bright, region: nil),
            "Malformed/missing outlines must retain the full glare check")
        print("Glare crop regression passed: outside-face reflection excluded; in-face glare still rejected at the unchanged threshold.")
    }
}
