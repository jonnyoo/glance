//
//  AnimationTint.swift
//  glance
//
//  Recolors the overlay's blue-on-black artwork at render time. The artwork is a single hue scaled by intensity,
//  so its blue channel doubles as a brightness mask: multiplying that mask by the target color keeps every
//  glow, blur and fade of the original while landing the full-strength strokes on the exact target color.
//

import AppKit
import AVFoundation
import CoreImage

enum AnimationTint {
    /// Returns `image` recolored to `color`, or `image` itself when the color is the artwork's own.
    nonisolated static func apply(_ color: UnlockAnimationColor, to image: CIImage) -> CIImage {
        guard let rgb = color.tintRGB, let filter = CIFilter(name: "CIColorMatrix") else { return image }
        // Core Image filters in linear light, so the sRGB target is linearized to come out exact once rendered.
        let red = linearized(rgb.red), green = linearized(rgb.green), blue = linearized(rgb.blue)
        filter.setValue(image, forKey: kCIInputImageKey)
        filter.setValue(CIVector(x: 0, y: 0, z: red, w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: 0, y: 0, z: green, w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: 0, y: 0, z: blue, w: 0), forKey: "inputBVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        return filter.outputImage?.cropped(to: image.extent) ?? image
    }

    /// Recolored copy of a still, or the still itself for the artwork's own color.
    nonisolated static func apply(_ color: UnlockAnimationColor, to image: NSImage) -> NSImage {
        guard color.tintRGB != nil,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return image }
        let output = apply(color, to: CIImage(cgImage: cgImage))
        guard let rendered = CIContext().createCGImage(output, from: output.extent) else { return image }
        return NSImage(cgImage: rendered, size: image.size)
    }

    /// A composition that recolors every frame of `asset`, or nil when no recoloring is needed.
    nonisolated static func videoComposition(for asset: AVAsset, color: UnlockAnimationColor) -> AVVideoComposition? {
        guard color.tintRGB != nil else { return nil }
        let composition = AVMutableVideoComposition(asset: asset) { request in
            request.finish(with: apply(color, to: request.sourceImage), context: nil)
        }
        // The bundled videos are tagged SMPTE-C; rendering out in Rec. 709 (sRGB's primaries) keeps the tint the
        // same color as the tinted still instead of drifting more saturated.
        composition.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        composition.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        composition.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return composition
    }

    private nonisolated static func linearized(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
}
