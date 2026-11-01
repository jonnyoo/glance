//
//  EnrollmentPoseEvaluator.swift
//  glance
//
//  Pure, camera-angle-adaptive pose matching for guided nine-pose face enrollment.
//  Calibrates the user's neutral (yaw, pitch) baseline during `.center` so laptop
//  webcams tilted below eye level (e.g. -0.30 ... -0.42 rad) never false-trigger
//  "Too far up" or block directional pose capture.
//  Supports omni-directional, circular Face ID-style enrollment across all 360 degrees.
//

import Foundation

/// A single guided head pose captured during enrollment — center plus the
/// 8 compass directions.
nonisolated enum EnrollmentPose: Int, CaseIterable, Sendable {
    case center, left, topLeft, top, topRight, right, bottomRight, bottom, bottomLeft

    nonisolated enum YawBand: Sendable { case left, none, right }
    nonisolated enum PitchBand: Sendable { case up, none, down }

    var yawBand: YawBand {
        switch self {
        case .left, .topLeft, .bottomLeft: return .left
        case .right, .topRight, .bottomRight: return .right
        case .center, .top, .bottom: return .none
        }
    }

    var pitchBand: PitchBand {
        switch self {
        case .top, .topLeft, .topRight: return .up
        case .bottom, .bottomLeft, .bottomRight: return .down
        case .center, .left, .right: return .none
        }
    }

    /// Compass angle (0 = up, clockwise) this pose's ring sector is centered
    /// on. `nil` for center, which pulses the whole ring instead of
    /// claiming a sector.
    var compassAngle: Double? {
        switch self {
        case .center: return nil
        case .top: return 0
        case .topRight: return 45
        case .right: return 90
        case .bottomRight: return 135
        case .bottom: return 180
        case .bottomLeft: return 225
        case .left: return 270
        case .topLeft: return 315
        }
    }

    var instruction: String {
        switch self {
        case .center: return "Look straight at the camera"
        case .top: return "Tilt your head slightly up"
        case .topRight: return "Tilt your head up and right"
        case .right: return "Turn your head slightly right"
        case .bottomRight: return "Tilt your head down and right"
        case .bottom: return "Tilt your head slightly down"
        case .bottomLeft: return "Tilt your head down and left"
        case .left: return "Turn your head slightly left"
        case .topLeft: return "Tilt your head up and left"
        }
    }

    /// Relaxes this pose's yaw/pitch bands — same knob as `stallWidenFactor`, so >1 is easier.
    var matchLeniency: Float {
        switch self {
        case .bottomLeft, .bottomRight: return 1.40
        case .topLeft, .topRight: return 1.30
        case .top, .bottom: return 1.15
        default: return 1.0
        }
    }

    /// Persisted alongside each sample so a saved identity records which
    /// pose each embedding came from.
    var name: String {
        switch self {
        case .center: return "center"
        case .left: return "left"
        case .topLeft: return "top_left"
        case .top: return "top"
        case .topRight: return "top_right"
        case .right: return "right"
        case .bottomRight: return "bottom_right"
        case .bottom: return "bottom"
        case .bottomLeft: return "bottom_left"
        }
    }
}

nonisolated enum EnrollmentExcessiveTurn: Equatable, Sendable {
    case left, topLeft, up, topRight, right, bottomRight, down, bottomLeft

    var instruction: String {
        switch self {
        case .left: return "Too far left"
        case .topLeft: return "Too far toward the top left"
        case .up: return "Too far up"
        case .topRight: return "Too far toward the top right"
        case .right: return "Too far right"
        case .bottomRight: return "Too far toward the bottom right"
        case .down: return "Too far down"
        case .bottomLeft: return "Too far toward the bottom left"
        }
    }
}

/// Where the head is currently turned, for the ring's live indicator.
nonisolated struct EnrollmentHeadTurn: Equatable, Sendable {
    /// Compass angle (0 = up, clockwise) — same frame as `EnrollmentPose.compassAngle`.
    let angle: Double
    /// How far the turn has gone toward the threshold, 0...1.
    let progress: Double
}

/// Immutable value-type evaluator for guided enrollment poses.
/// Smooths Vision's frame-to-frame yaw/pitch jitter and calibrates a per-session neutral
/// camera-mount baseline from `.center` captures before evaluating the 8 directional poses.
nonisolated struct EnrollmentPoseEvaluator: Equatable, Sendable {
    static let stallWidenFactor: Float = 1.30

    private static let emaAlpha: Float = 0.50
    private static let headTurnDeadzone: Double = 0.12

    // `.center` envelope accommodates laptop lids tilted below eye level (-0.45 rad)
    // as well as external webcams mounted above tall displays (+0.35 rad).
    private static let centerYawLimit: Float = 0.22
    private static let centerPitchLimit: Float = 0.52
    private static let centerRawYawCap: Float = 0.52
    private static let centerRawPitchCap: Float = 0.62
    private static let neutralYawClamp: ClosedRange<Float> = -0.10...0.10
    private static let neutralPitchClamp: ClosedRange<Float> = -0.45...0.35

    // Directional pose bands, measured relative to `(neutralYaw, neutralPitch)`.
    // Vision uses +yaw for a left turn (matching mirrored preview) and -pitch for looking up.
    private static let yawInnerThreshold: Float = 0.18
    private static let yawCenterTolerance: Float = 0.20
    private static let yawOuterCap: Float = 0.55
    private static let pitchInnerThreshold: Float = 0.13
    private static let pitchCenterTolerance: Float = 0.22
    private static let pitchOuterCap: Float = 0.46

    // Physical Vision sensor limits beyond which 5-point landmarks degrade regardless of mount angle.
    private static let rawYawOuterCap: Float = 0.68
    private static let rawPitchOuterCap: Float = 0.72

    let smoothedYaw: Float?
    let smoothedPitch: Float?
    let neutralYaw: Float
    let neutralPitch: Float
    let centerYawSamples: [Float]
    let centerPitchSamples: [Float]
    let isCalibrated: Bool

    init(
        smoothedYaw: Float? = nil,
        smoothedPitch: Float? = nil,
        neutralYaw: Float = 0,
        neutralPitch: Float = 0,
        centerYawSamples: [Float] = [],
        centerPitchSamples: [Float] = [],
        isCalibrated: Bool = false
    ) {
        self.smoothedYaw = smoothedYaw
        self.smoothedPitch = smoothedPitch
        self.neutralYaw = neutralYaw
        self.neutralPitch = neutralPitch
        self.centerYawSamples = centerYawSamples
        self.centerPitchSamples = centerPitchSamples
        self.isCalibrated = isCalibrated
    }

    /// Clears transient smoothed pose when face tracking drops, preserving any calibrated baseline.
    func clearedFrame() -> EnrollmentPoseEvaluator {
        EnrollmentPoseEvaluator(
            smoothedYaw: nil,
            smoothedPitch: nil,
            neutralYaw: neutralYaw,
            neutralPitch: neutralPitch,
            centerYawSamples: centerYawSamples,
            centerPitchSamples: centerPitchSamples,
            isCalibrated: isCalibrated
        )
    }

    /// Incorporates a new raw `(yaw, pitch)` observation using an exponential moving average.
    func observing(rawYaw: Float, rawPitch: Float) -> EnrollmentPoseEvaluator {
        let nextYaw = smoothedYaw.map { $0 + Self.emaAlpha * (rawYaw - $0) } ?? rawYaw
        let nextPitch = smoothedPitch.map { $0 + Self.emaAlpha * (rawPitch - $0) } ?? rawPitch
        return EnrollmentPoseEvaluator(
            smoothedYaw: nextYaw,
            smoothedPitch: nextPitch,
            neutralYaw: neutralYaw,
            neutralPitch: neutralPitch,
            centerYawSamples: centerYawSamples,
            centerPitchSamples: centerPitchSamples,
            isCalibrated: isCalibrated
        )
    }

    /// Records a verified `.center` capture sample toward neutral camera-angle calibration.
    func recordingCenterSample(yaw: Float, pitch: Float) -> EnrollmentPoseEvaluator {
        EnrollmentPoseEvaluator(
            smoothedYaw: smoothedYaw,
            smoothedPitch: smoothedPitch,
            neutralYaw: neutralYaw,
            neutralPitch: neutralPitch,
            centerYawSamples: centerYawSamples + [yaw],
            centerPitchSamples: centerPitchSamples + [pitch],
            isCalibrated: isCalibrated
        )
    }

    /// Locks in `(neutralYaw, neutralPitch)` from collected `.center` samples, clamped to physical mount bounds.
    func calibratingFromCenterSamples() -> EnrollmentPoseEvaluator {
        guard !centerYawSamples.isEmpty, !centerPitchSamples.isEmpty else { return self }
        let meanYaw = centerYawSamples.reduce(0, +) / Float(centerYawSamples.count)
        let meanPitch = centerPitchSamples.reduce(0, +) / Float(centerPitchSamples.count)
        let clampedYaw = min(max(meanYaw, Self.neutralYawClamp.lowerBound), Self.neutralYawClamp.upperBound)
        let clampedPitch = min(max(meanPitch, Self.neutralPitchClamp.lowerBound), Self.neutralPitchClamp.upperBound)
        return EnrollmentPoseEvaluator(
            smoothedYaw: smoothedYaw,
            smoothedPitch: smoothedPitch,
            neutralYaw: clampedYaw,
            neutralPitch: clampedPitch,
            centerYawSamples: centerYawSamples,
            centerPitchSamples: centerPitchSamples,
            isCalibrated: true
        )
    }

    /// Reports the dominant axis when a user has gone beyond enrollment's safe pose envelope.
    func excessiveTurn(for pose: EnrollmentPose) -> EnrollmentExcessiveTurn? {
        guard let yaw = smoothedYaw, let pitch = smoothedPitch else { return nil }

        let yawOvershoot: Float
        let pitchOvershoot: Float
        let isLeft: Bool
        let isUp: Bool

        if pose == .center {
            yawOvershoot = abs(yaw) / Self.centerRawYawCap
            pitchOvershoot = abs(pitch) / Self.centerRawPitchCap
            isLeft = yaw > 0
            isUp = pitch < 0
        } else {
            let relYaw = yaw - neutralYaw
            let relPitch = pitch - neutralPitch
            yawOvershoot = max(abs(relYaw) / Self.yawOuterCap, abs(yaw) / Self.rawYawOuterCap)
            pitchOvershoot = max(abs(relPitch) / Self.pitchOuterCap, abs(pitch) / Self.rawPitchOuterCap)
            isLeft = abs(relYaw) >= 0.01 ? (relYaw > 0) : (yaw > 0)
            isUp = abs(relPitch) >= 0.01 ? (relPitch < 0) : (pitch < 0)
        }

        guard max(yawOvershoot, pitchOvershoot) >= 1 else { return nil }

        if yawOvershoot >= 1, pitchOvershoot >= 1 {
            switch (isLeft, isUp) {
            case (true, true): return .topLeft
            case (false, true): return .topRight
            case (false, false): return .bottomRight
            case (true, false): return .bottomLeft
            }
        }

        if yawOvershoot >= pitchOvershoot {
            return isLeft ? .left : .right
        }
        return isUp ? .up : .down
    }

    /// Continuous head turn relative to neutral yaw/pitch, tracking smoothly across all 360 degrees.
    func globalHeadTurn() -> EnrollmentHeadTurn? {
        guard let yaw = smoothedYaw, let pitch = smoothedPitch else { return nil }
        let relYaw = yaw - neutralYaw
        let relPitch = pitch - neutralPitch
        let x = Double(-relYaw / Self.yawInnerThreshold)
        let y = Double(-relPitch / Self.pitchInnerThreshold)

        let magnitude = (x * x + y * y).squareRoot()
        guard magnitude > Self.headTurnDeadzone else { return nil }

        let degrees = atan2(x, y) * 180 / .pi
        return EnrollmentHeadTurn(
            angle: degrees < 0 ? degrees + 360 : degrees,
            progress: min(magnitude, 1)
        )
    }

    /// Maps continuous head turn angle (0 = top, clockwise) to the corresponding 45-degree sector pose.
    func sectorPose(for angleDegrees: Double) -> EnrollmentPose {
        let normalized = (angleDegrees.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
        let sectorIndex = Int(((normalized + 22.5) / 45.0).rounded(.down)) % 8
        switch sectorIndex {
        case 0: return .top          // 0° (Up)
        case 1: return .topRight     // 45°
        case 2: return .right        // 90° (Right)
        case 3: return .bottomRight  // 135°
        case 4: return .bottom       // 180° (Down)
        case 5: return .bottomLeft   // 225°
        case 6: return .left         // 270° (Left)
        case 7: return .topLeft      // 315°
        default: return .top
        }
    }

    /// Evaluates if the current head pose matches an uncaptured sector or center.
    /// Provides free-form Face ID style circular enrollment.
    func bestMatchingPose(
        uncaptured: Set<EnrollmentPose>,
        widened: Bool
    ) -> EnrollmentPose? {
        if uncaptured.contains(.center) {
            return matches(pose: .center, widened: widened) ? .center : nil
        }
        guard let turn = globalHeadTurn() else { return nil }
        let progressRequired = widened ? 0.60 : 0.72
        guard turn.progress >= progressRequired else { return nil }

        let targetPose = sectorPose(for: turn.angle)
        guard uncaptured.contains(targetPose) else { return nil }
        guard excessiveTurn(for: targetPose) == nil else { return nil }
        return targetPose
    }

    func matches(pose: EnrollmentPose, widened: Bool) -> Bool {
        guard let yaw = smoothedYaw, let pitch = smoothedPitch,
              excessiveTurn(for: pose) == nil else {
            return false
        }
        let factor = (widened ? Self.stallWidenFactor : 1.0) * pose.matchLeniency
        if pose == .center {
            return abs(yaw) < Self.centerYawLimit * factor
                && abs(pitch) < Self.centerPitchLimit * factor
        }
        guard let turn = globalHeadTurn() else { return false }
        let progressRequired = Double(0.70 / factor)
        guard turn.progress >= progressRequired else { return false }
        return sectorPose(for: turn.angle) == pose
    }
}
