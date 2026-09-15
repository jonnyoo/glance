//
//  SceneLuminance.swift
//  glance
//
//  Cheap "how dark is the room" estimate for a camera frame — a single CIAreaAverage reduction over the working frame.
//  Runs on the capture session queue alongside frame conversion, so it costs one small GPU pass per frame.
//

import CoreImage
import CoreGraphics

nonisolated enum SceneLuminance {
    /// Rec. 709 luma of the frame's average colour, 0 (black) … 1 (white). `nil` if Core Image couldn't reduce the image.
    /// The webcam's own auto-exposure already gains up dark scenes, so a genuinely dark room still lands well under
    /// `LowLightEnhancer.darknessThreshold` — but with heavy noise, which is what the enhancer and illuminator address.
    static func meanLuminance(of image: CIImage, context: CIContext) -> Float? {
        let extent = image.extent
        guard !extent.isEmpty, !extent.isInfinite else { return nil }
        guard let averaged = CIFilter(
            name: "CIAreaAverage",
            parameters: [kCIInputImageKey: image, kCIInputExtentKey: CIVector(cgRect: extent)]
        )?.outputImage else { return nil }

        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(
            averaged,
            toBitmap: &pixel,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
        let r = Float(pixel[0]) / 255
        let g = Float(pixel[1]) / 255
        let b = Float(pixel[2]) / 255
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}
