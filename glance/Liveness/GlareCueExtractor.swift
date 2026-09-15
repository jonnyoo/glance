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

    /// How far `CameraManager.renderCrop` grows the face box per side so the bezel and texture cues
    /// see background around it. renderCrop reads this constant, so glare's mapping of the face back
    /// out of the crop cannot drift from the crop itself.
    static let renderCropExpansion: CGFloat = 0.15

    /// Where `faceBoundingBox` lands inside the crop `renderCrop` made from it, in the crop's
    /// top-left pixel space. Follows renderCrop's clamp at the frame edge, which drops the margin on
    /// that side only, so the face isn't always the crop's centre.
    static func faceRect(of faceBoundingBox: CGRect, inFrameOfSize frameSize: CGSize, cropSize: CGSize) -> CGRect {
        let expanded = faceBoundingBox
            .insetBy(dx: -faceBoundingBox.width * renderCropExpansion, dy: -faceBoundingBox.height * renderCropExpansion)
            .intersection(CGRect(origin: .zero, size: frameSize))
        guard !expanded.isEmpty else { return CGRect(origin: .zero, size: cropSize) }

        let scaleX = cropSize.width / expanded.width
        let scaleY = cropSize.height / expanded.height
        return CGRect(
            x: (faceBoundingBox.minX - expanded.minX) * scaleX,
            y: (faceBoundingBox.minY - expanded.minY) * scaleY,
            width: faceBoundingBox.width * scaleX,
            height: faceBoundingBox.height * scaleY
        )
    }

    /// Returns `nil` only if the crop couldn't be rasterized; a too-small crop still
    /// yields a sample, discounted elsewhere via `cropPixelWidth`.
    ///
    /// - Parameter measurementRect: the part of the crop to measure, in its top-left pixel space.
    ///   A lamp, window or white wall in the crop's background margin passes the same neutral-white
    ///   test as screen glare, so the app passes `faceRect(of:inFrameOfSize:cropSize:)`. `nil`
    ///   measures the whole crop, for hand-cropped stills in `tools/glare_cue_probe.swift`.
    static func extract(faceCrop: CGImage, measurementRect: CGRect? = nil) -> GlareSample? {
        let width = faceCrop.width
        let height = faceCrop.height
        guard width > 0, height > 0 else { return nil }

        var region = CGRect(x: 0, y: 0, width: width, height: height)
        if let measurementRect {
            let clamped = measurementRect.integral.intersection(region)
            // Degenerate geometry measures the whole crop rather than dropping a deny cue.
            if !clamped.isEmpty { region = clamped }
        }
        let minX = Int(region.minX)
        let minY = Int(region.minY)
        let regionWidth = Int(region.width)
        let regionHeight = Int(region.height)

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
            // Buffer row 0 is the top of the drawn image, the same top-left space as `region`.
            for y in minY..<(minY + regionHeight) {
                let rowBase = y * width * 4
                let gy = min(clusterGridSize - 1, (y - minY) * clusterGridSize / regionHeight)
                for x in minX..<(minX + regionWidth) {
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
                    let gx = min(clusterGridSize - 1, (x - minX) * clusterGridSize / regionWidth)
                    gridCounts[gy * clusterGridSize + gx] += 1
                }
            }
        }

        let pixelCount = regionWidth * regionHeight
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
