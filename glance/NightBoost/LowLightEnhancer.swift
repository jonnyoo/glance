//
//  LowLightEnhancer.swift
//  glance
//
//  Software gain for dark frames: denoise, then push exposure toward a mid-grey target, then lift shadows. Applied to the
//  640px working frame only (what Vision and ArcFace see), never to the native-resolution crop the glare cue reads — a
//  brightened crop would push highlights to near-white and trip the specular-glare deny cue on a perfectly live face.
//

import CoreImage
import CoreGraphics

nonisolated enum LowLightEnhancer {
    /// Mirror of `GlanceSettings.nightBoostEnabled`, written on the main actor and read from the capture session queue
    /// — same deliberate, benign race as `FaceRecognitionPipeline.minimumProminentFaceWidth`.
    nonisolated(unsafe) static var isEnabled = true

    /// Mean luma below which a frame counts as "dark". The FaceTime camera's auto-exposure lifts a dim room to roughly
    /// 0.05–0.15 (noisy); a normally lit room sits at 0.3+. Shared by the frame enhancer and `SceneIlluminator`.
    static let darknessThreshold: Float = 0.16

    /// Exposure target, set *pre*-gamma: the shadow lift that runs after `CIExposureAdjust` adds roughly another 20%,
    /// so 0.33 here lands a finished frame near 0.40 mean luma. Mid-grey rather than 0.5 so highlights stay unblown —
    /// a blown highlight is what the glare deny cue reads as a spoof.
    private static let targetLuminance: Float = 0.33
    /// +4 EV is a 16x linear gain. Denoising runs first, which is what makes this survivable; past this the sensor's
    /// own noise floor is all that's left to amplify.
    private static let maxExposureBoost: Float = 4.0

    /// `SceneLuminance` reports a gamma-encoded (display-space) value, but `CIExposureAdjust` multiplies *linear*
    /// radiance. Taking the ratio in display space silently under-corrects, and worst in the darkest rooms where the
    /// curve is steepest — so both ends of the ratio are linearised first.
    private static func srgbToLinear(_ channel: Float) -> Float {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    /// Returns the same image untouched when the scene is not dark or the feature is off.
    static func enhance(_ image: CIImage, meanLuminance: Float) -> CIImage {
        guard isEnabled, meanLuminance < darknessThreshold else { return image }
        let extent = image.extent
        let linearMean = max(srgbToLinear(meanLuminance), 0.0002)
        let ev = min(maxExposureBoost, max(0, log2(srgbToLinear(targetLuminance) / linearMean)))

        // Denoise *before* gain — the reduction filter's threshold is absolute, so amplified noise would sail past it.
        var output = image.applyingFilter("CINoiseReduction", parameters: [
            "inputNoiseLevel": 0.03,
            "inputSharpness": 0.4,
        ])
        output = output.applyingFilter("CIExposureAdjust", parameters: ["inputEV": ev])
        // Gamma < 1 lifts shadows without touching white — where the eyes and nostrils ArcFace keys on hide in a dark frame.
        output = output.applyingFilter("CIGammaAdjust", parameters: ["inputPower": 0.8])
        return output.cropped(to: extent)
    }
}
