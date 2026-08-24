//
//  GlareCue.swift
//  glance
//
//  Per-frame specular-highlight measurement, the pixel-domain half of the
//  gloss/glare liveness cue (see `LivenessCues.glossGlare`). Deliberately
//  has no Vision/CoreImage import, only `CoreGraphics` — same discipline as
//  `LivenessFrame` in `LivenessScoring.swift` — so this type and everything
//  that scores it stay usable from `tools/liveness_selftest.swift` with
//  synthetic data, no camera or Vision pipeline required.
//
//  Populated from a native-resolution face crop by
//  `GlareCueExtractor.extract(faceCrop:)` (`GlareCueExtractor.swift`, which
//  does need CoreImage) — this struct itself has no idea where the numbers
//  came from.
//
//  This started life as a much wider `SpoofCueSample` carrying seven
//  appearance measurements (spectral high-frequency ratio, Laplacian
//  sharpness spread, chroma statistics, a moiré peak ratio, per-row luma
//  profiles). Real-device testing found only the specular pair actually
//  separated a live face from a phone screen — the rest read identically,
//  backwards, or pinned at a constant — so they were removed rather than
//  left as dead weight, taking the whole Accelerate/FFT path with them.
//

import CoreGraphics

struct GlareSample: Equatable {
    /// Width in native pixels of the crop this was measured from.
    /// `CameraManager.renderCrop` only ever downsamples, never upsamples,
    /// so this is a direct, honest measure of how much real detail was
    /// available — the cue confidence-weights down as this shrinks.
    let cropPixelWidth: CGFloat

    /// Fraction of crop pixels that are near-saturated and low-chroma
    /// (bright, close to gray) — direct specular reflection.
    let specularFraction: Float

    /// How concentrated those specular pixels are into a single region
    /// (densest 8x8 grid cell's share of all of them) rather than spread
    /// across many small points. This is what turns "some bright pixels
    /// somewhere" into "one big glare blob", and it's the half that
    /// actually distinguishes glass from a shiny forehead.
    let specularClusterRatio: Float
}
