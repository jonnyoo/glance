//
//  FaceEmbedder.swift
//  FaceUnlock
//

import Foundation
import CoreML
import CoreGraphics

enum FaceEmbedderError: LocalizedError {
    case modelNotFound
    case preprocessingFailed
    case predictionFailed
    case modelLoadFailed(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .modelNotFound:
            return "Face embedding model is missing from the app bundle. Add ArcFace.mlpackage (or FaceEmbedding.mlpackage) to the FaceUnlock target."
        case .preprocessingFailed:
            return "Couldn't preprocess the face image for the model."
        case .predictionFailed:
            return "Face embedding prediction failed."
        case .modelLoadFailed(let error):
            return "Couldn't load FaceEmbedding model: \(error.localizedDescription)"
        }
    }
}

final class FaceEmbedder {
    static let inputSize = 112
    static let embeddingDimension = 512

    private let model: MLModel
    private let inputName: String
    private let outputName: String

    /// Currently-loaded model name (e.g. "ArcFace" or "FaceEmbedding"). Useful for diagnostics.
    let modelName: String

    init() throws {
        // Prefer ArcFace (buffalo_l ResNet50, higher accuracy) if present, else fall back to
        // MobileFaceNet (buffalo_sc, faster + smaller). Both output 512-d L2-normalized embeddings.
        let candidates = ["ArcFace", "FaceEmbedding"]
        var loaded: (MLModel, String)? = nil
        let config = MLModelConfiguration()
        config.computeUnits = .all

        for name in candidates {
            guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else {
                continue
            }
            do {
                let m = try MLModel(contentsOf: url, configuration: config)
                loaded = (m, name)
                break
            } catch {
                // try next candidate
                continue
            }
        }

        guard let (model, name) = loaded else {
            throw FaceEmbedderError.modelNotFound
        }

        self.model = model
        self.modelName = name

        // Both InsightFace conversions tend to have a single input. Discover its name
        // dynamically instead of hardcoding (`face_image` for MobileFaceNet, `input_1` for ArcFace).
        let description = model.modelDescription
        guard let firstInput = description.inputDescriptionsByName.keys.first else {
            throw FaceEmbedderError.predictionFailed
        }
        self.inputName = firstInput

        // Output: prefer one literally named "embedding" (MobileFaceNet); otherwise the first
        // available output (ArcFace's auto-generated `var_1110`).
        let outputs = description.outputDescriptionsByName
        if outputs["embedding"] != nil {
            self.outputName = "embedding"
        } else if let firstOutput = outputs.keys.first {
            self.outputName = firstOutput
        } else {
            throw FaceEmbedderError.predictionFailed
        }
    }

    func embed(faceImage: CGImage) throws -> [Float] {
        // Step 1: render the aligned face to a 112×112 RGBA byte buffer, then apply
        // CLAHE to normalize lighting. Both TTA passes below share this buffer, so
        // the expensive draw + CLAHE only run once.
        let normalizedPixels = try renderAndNormalizePixels(from: faceImage)

        // Step 2: Test-Time Augmentation — original + horizontal mirror.
        let embOriginal = try predictEmbedding(from: normalizedPixels, flipped: false)
        let embFlipped  = try predictEmbedding(from: normalizedPixels, flipped: true)

        guard embOriginal.count == embFlipped.count else {
            // Defensive — both come from the same model so this shouldn't happen.
            return embOriginal
        }
        var mean = [Float](repeating: 0, count: embOriginal.count)
        for i in 0..<embOriginal.count {
            mean[i] = (embOriginal[i] + embFlipped[i]) * 0.5
        }
        // Re-normalize: average of two unit vectors is not unit length in general.
        return Self.l2Normalize(mean)
    }

    /// Rasterize the CGImage into a 112×112 RGBA byte buffer, then normalize
    /// lighting in two stages:
    ///
    ///   1. **Global gamma correction** — targets the mean luminance to 127
    ///      (mid-gray). Fixes the "dim room vs bright room" mismatch that CLAHE
    ///      alone can't close, because CLAHE only fixes local contrast within
    ///      an image, not the global exposure gap between different images.
    ///   2. **CLAHE** — local per-tile contrast equalization on top. Handles
    ///      residual within-image variation (e.g. shadowed cheek vs lit forehead).
    private func renderAndNormalizePixels(from cgImage: CGImage) throws -> [UInt8] {
        let size = Self.inputSize
        var pixels = [UInt8](repeating: 0, count: size * size * 4)
        guard let context = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw FaceEmbedderError.preprocessingFailed
        }
        context.interpolationQuality = .high
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        Self.normalizeGlobalExposure(pixels: &pixels, size: size)
        Self.applyCLAHE(pixels: &pixels, size: size)
        return pixels
    }

    // MARK: - Global exposure normalization

    /// Bring the face's mean luminance close to 127 by applying a per-pixel gamma
    /// correction. Standardizes the average brightness across lighting conditions
    /// so downstream CLAHE and the ArcFace model see comparable input distributions.
    ///
    /// The gamma exponent is chosen so that a pixel of value `mean` maps to `target`:
    ///     (mean/255)^γ = target/255   →   γ = log(target/255) / log(mean/255)
    ///
    /// Applied uniformly to R, G, B (via a 256-entry LUT), so color hue is preserved.
    /// Skipped when the image is already well-exposed (near the target) to avoid
    /// distorting already-good frames.
    private static func normalizeGlobalExposure(pixels: inout [UInt8], size: Int) {
        // Rec.601 luma mean, computed inline to avoid a temp buffer.
        var totalLuma: Int = 0
        let pixelCount = size * size
        for p in 0..<pixelCount {
            let base = p * 4
            totalLuma += (299 * Int(pixels[base])
                        + 587 * Int(pixels[base + 1])
                        + 114 * Int(pixels[base + 2])
                        + 500) / 1000
        }
        let mean = Float(totalLuma) / Float(pixelCount)
        let target: Float = 127.0

        // Skip if too dark to compute meaningfully OR already close enough to target.
        // Tighter threshold (8 vs 12) makes the gamma pull trigger more often in
        // typical room light where mean luminance drifts to ~110–120.
        guard mean > 5, abs(mean - target) > 8 else { return }

        // γ such that pow(mean/255, γ) = target/255.
        let gamma = log(target / 255.0) / log(mean / 255.0)

        // Precompute 256-entry gamma LUT to avoid per-pixel pow().
        var lut = [UInt8](repeating: 0, count: 256)
        for i in 0..<256 {
            let corrected = powf(Float(i) / 255.0, gamma) * 255.0
            lut[i] = UInt8(min(255, max(0, Int(corrected + 0.5))))
        }

        // Apply uniformly to R, G, B (alpha untouched).
        for p in 0..<pixelCount {
            let base = p * 4
            pixels[base]     = lut[Int(pixels[base])]
            pixels[base + 1] = lut[Int(pixels[base + 1])]
            pixels[base + 2] = lut[Int(pixels[base + 2])]
        }
    }

    /// One Core ML forward pass. `flipped` mirrors the input horizontally during
    /// preprocessing (no separate CGImage flip — we just read pixel columns in
    /// reverse when unpacking into the MLMultiArray).
    private func predictEmbedding(from pixels: [UInt8], flipped: Bool) throws -> [Float] {
        let input = try makeInputArray(from: pixels, flipped: flipped)
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            inputName: MLFeatureValue(multiArray: input)
        ])
        let output: MLFeatureProvider
        do {
            output = try model.prediction(from: provider)
        } catch {
            throw FaceEmbedderError.predictionFailed
        }
        guard let multiArray = output.featureValue(for: outputName)?.multiArrayValue else {
            throw FaceEmbedderError.predictionFailed
        }
        let raw = Self.float32Array(from: multiArray)
        return Self.l2Normalize(raw)
    }

    private func makeInputArray(from pixels: [UInt8], flipped: Bool) throws -> MLMultiArray {
        let size = Self.inputSize
        let array: MLMultiArray
        do {
            array = try MLMultiArray(
                shape: [1, 3, NSNumber(value: size), NSNumber(value: size)],
                dataType: .float32
            )
        } catch {
            throw FaceEmbedderError.preprocessingFailed
        }
        let ptr = array.dataPointer.assumingMemoryBound(to: Float32.self)
        let plane = size * size
        for y in 0..<size {
            for x in 0..<size {
                // Read the source column from the mirrored X when `flipped`; the write
                // position `pixelIdx` stays sequential so the tensor layout is unchanged.
                let srcX = flipped ? (size - 1 - x) : x
                let i = (y * size + srcX) * 4
                let r = (Float(pixels[i])     - 127.5) / 127.5
                let g = (Float(pixels[i + 1]) - 127.5) / 127.5
                let b = (Float(pixels[i + 2]) - 127.5) / 127.5
                let pixelIdx = y * size + x
                ptr[0 * plane + pixelIdx] = r
                ptr[1 * plane + pixelIdx] = g
                ptr[2 * plane + pixelIdx] = b
            }
        }
        return array
    }

    // MARK: - CLAHE

    /// Contrast-Limited Adaptive Histogram Equalization applied in-place on RGBA
    /// pixels. Works on the Rec.601 luminance channel: per-tile histogram → clip
    /// (redistribute excess) → CDF lookup → bilinear interpolation between tile
    /// centers → per-pixel gain applied to R, G, B (color hue preserved).
    ///
    /// Tuning: 8×8 tile grid (14×14 pixels each for 112×112 input); clip factor 4
    /// (limits per-bin count to 4× the uniform-histogram baseline). Matches
    /// OpenCV's `cv2.createCLAHE(tileGridSize=(8,8))` default which is the standard
    /// for face-recognition preprocessing — finer tiles adapt to local lighting
    /// (lit forehead vs. shadowed cheek) more accurately than the coarser 4×4 grid.
    private static func applyCLAHE(pixels: inout [UInt8], size: Int) {
        let numTiles = 8
        let tileSize = size / numTiles                    // 14 for size=112
        let pixelsPerTile = tileSize * tileSize           // 196
        // Clip limit = 4 × (uniform per-bin count) = 4 × (196 / 256) ≈ 3
        let clipLimit = max(2, (4 * pixelsPerTile) / 256)

        // --- Compute luminance ---
        var luma = [UInt8](repeating: 0, count: size * size)
        for p in 0..<(size * size) {
            let base = p * 4
            // Rec.601 fixed-point: Y = (299R + 587G + 114B + 500) / 1000
            let y = (299 * Int(pixels[base])
                   + 587 * Int(pixels[base + 1])
                   + 114 * Int(pixels[base + 2])
                   + 500) / 1000
            luma[p] = UInt8(min(255, max(0, y)))
        }

        // --- Per-tile LUT: input Y → equalized Y (flat storage for speed) ---
        var luts = [UInt8](repeating: 0, count: numTiles * numTiles * 256)
        for ty in 0..<numTiles {
            for tx in 0..<numTiles {
                var hist = [Int](repeating: 0, count: 256)
                let y0 = ty * tileSize
                let x0 = tx * tileSize
                for yy in y0..<(y0 + tileSize) {
                    let rowBase = yy * size
                    for xx in x0..<(x0 + tileSize) {
                        hist[Int(luma[rowBase + xx])] += 1
                    }
                }
                // Clip and count excess
                var excess = 0
                for i in 0..<256 {
                    if hist[i] > clipLimit {
                        excess += hist[i] - clipLimit
                        hist[i] = clipLimit
                    }
                }
                // Redistribute excess uniformly (with per-bin remainder to preserve total)
                let addPerBin = excess / 256
                let leftover = excess % 256
                for i in 0..<256 {
                    hist[i] += addPerBin + (i < leftover ? 1 : 0)
                }
                // CDF → LUT
                let lutBase = (ty * numTiles + tx) * 256
                var cum = 0
                for i in 0..<256 {
                    cum += hist[i]
                    luts[lutBase + i] = UInt8(min(255, (cum * 255) / pixelsPerTile))
                }
            }
        }

        // --- Apply LUTs with bilinear interpolation between tile centers ---
        let tsF = Float(tileSize)
        let halfTile = tsF * 0.5
        let lastTile = numTiles - 1
        for y in 0..<size {
            let tyF = (Float(y) - halfTile) / tsF
            var ty0 = Int(floor(tyF))
            let dy = tyF - Float(ty0)
            var ty1 = ty0 + 1
            if ty0 < 0 { ty0 = 0 } else if ty0 > lastTile { ty0 = lastTile }
            if ty1 < 0 { ty1 = 0 } else if ty1 > lastTile { ty1 = lastTile }

            let rowBase = y * size
            for x in 0..<size {
                let txF = (Float(x) - halfTile) / tsF
                var tx0 = Int(floor(txF))
                let dx = txF - Float(tx0)
                var tx1 = tx0 + 1
                if tx0 < 0 { tx0 = 0 } else if tx0 > lastTile { tx0 = lastTile }
                if tx1 < 0 { tx1 = 0 } else if tx1 > lastTile { tx1 = lastTile }

                let yValue = Int(luma[rowBase + x])
                let v00 = Float(luts[(ty0 * numTiles + tx0) * 256 + yValue])
                let v01 = Float(luts[(ty0 * numTiles + tx1) * 256 + yValue])
                let v10 = Float(luts[(ty1 * numTiles + tx0) * 256 + yValue])
                let v11 = Float(luts[(ty1 * numTiles + tx1) * 256 + yValue])
                let a = v00 * (1 - dx) + v01 * dx
                let b = v10 * (1 - dx) + v11 * dx
                let newY = a * (1 - dy) + b * dy

                // Apply gain to RGB so color hue is preserved. Guard against div-by-zero
                // for pure-black pixels (rare in a face crop, but be safe).
                let oldY = Float(yValue)
                let gain: Float = oldY > 1 ? newY / oldY : 1
                let pi = (rowBase + x) * 4
                let r  = min(255, max(0, Float(pixels[pi])     * gain))
                let g  = min(255, max(0, Float(pixels[pi + 1]) * gain))
                let bc = min(255, max(0, Float(pixels[pi + 2]) * gain))
                pixels[pi]     = UInt8(r + 0.5)
                pixels[pi + 1] = UInt8(g + 0.5)
                pixels[pi + 2] = UInt8(bc + 0.5)
                // Alpha (pi + 3) is left unchanged.
            }
        }
    }

    private static func float32Array(from array: MLMultiArray) -> [Float] {
        let count = array.count
        let ptr = array.dataPointer.assumingMemoryBound(to: Float32.self)
        return Array(UnsafeBufferPointer(start: ptr, count: count))
    }

    static func l2Normalize(_ vec: [Float]) -> [Float] {
        var sumSquares: Float = 0
        for v in vec { sumSquares += v * v }
        let norm = sqrtf(sumSquares)
        guard norm > 0 else { return vec }
        return vec.map { $0 / norm }
    }

    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
        }
        return dot
    }
}
