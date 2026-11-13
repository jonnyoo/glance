//
//  GlareCueExtractor.swift
//  glance
//
//  Turns a native-resolution face crop into a `GlareSample`. One decode-and-scan
//  pass, no frequency-domain work — cheap enough to run on every liveness frame.
//

import CoreGraphics

nonisolated enum GlareCueExtractor {
    /// Near-white, near-gray pixel — signature of a direct specular highlight vs. a bright colored surface.
    private static let specularLumaFloor: Float = 235
    private static let specularChromaTolerance: Float = 10

    /// Coarse on purpose — just distinguishes "one blob" from "many scattered points".
    private static let clusterGridSize = 8

    /// Returns `nil` only if the crop couldn't be rasterized; a too-small crop still
    /// yields a sample, discounted elsewhere via `cropPixelWidth`.
    static func extract(faceCrop: CGImage, faceRegion: [CGPoint]? = nil) -> GlareSample? {
        let width = faceCrop.width
        let height = faceCrop.height
        guard width > 0, height > 0 else { return nil }

        var data = [UInt8](repeating: 0, count: width * height * 4)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = data.withUnsafeMutableBytes({ buffer -> CGContext? in
            CGContext(
                data: buffer.baseAddress,
                width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        }) else { return nil }
        context.draw(faceCrop, in: CGRect(x: 0, y: 0, width: width, height: height))

        let mask = faceRegion.flatMap { regionMask($0, width: width, height: height) }
        let pixelCount = mask.map { $0.reduce(0) { $0 + ($1 == 0 ? 0 : 1) } } ?? width * height

        var gridCounts = [Int](repeating: 0, count: clusterGridSize * clusterGridSize)
        var specularTotal = 0

        data.withUnsafeBufferPointer { bytes in
            for y in 0..<height {
                let rowBase = y * width * 4
                let gy = min(clusterGridSize - 1, y * clusterGridSize / height)
                for x in 0..<width {
                    if let mask, mask[y * width + x] == 0 { continue }
                    let offset = rowBase + x * 4
                    let r = Float(bytes[offset])
                    let g = Float(bytes[offset + 1])
                    let b = Float(bytes[offset + 2])

                    let luma = 0.299 * r + 0.587 * g + 0.114 * b
                    guard luma >= specularLumaFloor else { continue }
                    let cb = -0.168736 * r - 0.331264 * g + 0.5 * b + 128
                    let cr = 0.5 * r - 0.418688 * g - 0.081312 * b + 128
                    guard abs(cb - 128) <= specularChromaTolerance,
                          abs(cr - 128) <= specularChromaTolerance
                    else { continue }

                    specularTotal += 1
                    let gx = min(clusterGridSize - 1, x * clusterGridSize / width)
                    gridCounts[gy * clusterGridSize + gx] += 1
                }
            }
        }

        let specularFraction = Float(specularTotal) / Float(pixelCount)
        let largestCluster = gridCounts.max() ?? 0
        let clusterRatio = specularTotal > 0 ? Float(largestCluster) / Float(specularTotal) : 0

        return GlareSample(
            cropPixelWidth: CGFloat(width),
            specularFraction: specularFraction,
            specularClusterRatio: clusterRatio
        )
    }

    /// Invalid or undersized masks fall back to the full crop, never a missing
    /// glare cue. A small outer margin tolerates landmark jitter at the edge.
    /// The denominator counts only retained pixels, so masking background does
    /// not dilute a highlight that is actually on the face.
    static func regionMask(_ polygon: [CGPoint], width: Int, height: Int) -> [UInt8]? {
        guard width > 0, height > 0, polygon.count >= 5,
              polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (-0.1...1.1).contains($0.x) && (-0.1...1.1).contains($0.y) }) else { return nil }
        var mask = [UInt8](repeating: 0, count: width * height)
        let valid = mask.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.setShouldAntialias(false)
            context.setFillColor(gray: 1, alpha: 1)
            context.setStrokeColor(gray: 1, alpha: 1)
            context.setLineJoin(.round)
            context.setLineWidth(CGFloat(min(width, height)) * 0.05)
            context.addLines(between: polygon.map { CGPoint(x: $0.x * CGFloat(width), y: (1 - $0.y) * CGFloat(height)) })
            context.closePath()
            context.drawPath(using: .fillStroke)
            return true
        }
        guard valid, mask.filter({ $0 != 0 }).count >= width * height * 2 / 5 else { return nil }
        return mask
    }
}
