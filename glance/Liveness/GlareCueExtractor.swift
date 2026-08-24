//
//  GlareCueExtractor.swift
//  glance
//
//  The pixel-facing half of the gloss/glare cue: turns one
//  native-resolution face crop into a `GlareSample` (`GlareCue.swift`,
//  which has no CoreImage dependency) — the same split as
//  `LivenessFeatures.swift` / `LivenessScoring.swift`, and for the same
//  reason: keep the pure decision logic (`LivenessCues.swift`) compiling
//  standalone in `tools/liveness_selftest.swift`.
//
//  One decode-and-scan pass over the crop's pixels, no frequency-domain
//  work — cheap enough to run on every liveness frame, same budget class as
//  `DeviceBezelDetector`.
//

import CoreGraphics

nonisolated enum GlareCueExtractor {
    /// Near-white, near-gray pixel — the signature of a direct specular
    /// highlight (a light source reflecting straight off glass or skin)
    /// rather than a bright but still-colored surface.
    private static let specularLumaFloor: Float = 235
    private static let specularChromaTolerance: Float = 10

    /// Grid resolution for the clustering measure. Coarse on purpose: the
    /// question is "is the glare one blob or many scattered points", which
    /// a fine grid would answer no better and a 2x2 would answer for free
    /// no matter what the glare looks like.
    private static let clusterGridSize = 8

    /// Returns `nil` only if the crop couldn't be rasterized at all. A crop
    /// too small to be informative still yields a sample — `LivenessCues
    /// .glossGlare` discounts it via `cropPixelWidth`, rather than this
    /// silently dropping the frame.
    static func extract(faceCrop: CGImage) -> GlareSample? {
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

        var gridCounts = [Int](repeating: 0, count: clusterGridSize * clusterGridSize)
        var specularTotal = 0

        data.withUnsafeBufferPointer { bytes in
            for y in 0..<height {
                let rowBase = y * width * 4
                let gy = min(clusterGridSize - 1, y * clusterGridSize / height)
                for x in 0..<width {
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

        let pixelCount = width * height
        let specularFraction = Float(specularTotal) / Float(pixelCount)
        let largestCluster = gridCounts.max() ?? 0
        let clusterRatio = specularTotal > 0 ? Float(largestCluster) / Float(specularTotal) : 0

        return GlareSample(
            cropPixelWidth: CGFloat(width),
            specularFraction: specularFraction,
            specularClusterRatio: clusterRatio
        )
    }
}
