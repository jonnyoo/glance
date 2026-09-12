//
//  EnrollmentPoseGeometry.swift
//  glance
//
//  The pure geometry behind guided enrollment: turning Vision's yaw/pitch into a direction and deciding whether that
//  direction satisfies a pose. Deliberately free of AppKit, actors and app state so `tools/enrollment_selftest.swift`
//  can compile this exact source and test the shipping implementation rather than a copy of it.
//
//  Everything the progress ring shows and everything the gate accepts is derived from `Turn`, so the two cannot
//  disagree — which they used to, by a factor of 1.41 on the diagonals.
//

import Foundation

nonisolated enum EnrollmentPoseGeometry {
    // MARK: - Bands, in radians

    /// How far the head must turn on each axis before a directional pose counts. These set the unit of `Turn`.
    static let yawInnerThreshold: Float = 0.25
    static let pitchInnerThreshold: Float = 0.20
    /// How still the head must be for the centre pose, which is a box around the origin rather than a direction.
    static let yawCenterTolerance: Float = 0.18
    static let pitchCenterTolerance: Float = 0.15

    /// Eight compass sectors.
    static let sectorWidth: Double = 45
    /// Upper bound on a turn, replacing the old per-axis outer caps that rejected wild Vision estimates. In `Turn`
    /// units those were yawOuterCap/yawInnerThreshold = 4.8 and pitchOuterCap/pitchInnerThreshold = 4.5; the lower
    /// of the two keeps the stricter behaviour.
    static let outerMagnitudeCap: Double = 4.5

    // MARK: - Turn

    /// A head direction, normalized so 1.0 means "turned far enough".
    struct Turn: Equatable {
        /// Screen-right, in units of `yawInnerThreshold`.
        let x: Double
        /// Up, in units of `pitchInnerThreshold`.
        let y: Double

        var magnitude: Double { (x * x + y * y).squareRoot() }

        /// Compass degrees, 0 = up, clockwise — the same frame as `EnrollmentPose.compassAngle`.
        var compassAngle: Double {
            let degrees = atan2(x, y) * 180 / .pi
            return degrees < 0 ? degrees + 360 : degrees
        }

        /// Beyond this the Vision estimate is not trustworthy and no pose accepts it, so nothing should render as ready.
        var isWithinRange: Bool { magnitude <= outerMagnitudeCap }
    }

    /// Vision inverts both axes against the screen: +yaw turns left, +pitch looks down.
    static func turn(yaw: Float, pitch: Float) -> Turn {
        Turn(x: Double(-yaw / yawInnerThreshold), y: Double(-pitch / pitchInnerThreshold))
    }

    /// How far the head must turn, in `Turn` units. `factor` folds in per-pose leniency and the stall widening; both
    /// make this smaller, exactly as they used to widen the rectangular bands.
    static func requiredMagnitude(factor: Float) -> Double {
        1.0 / Double(factor)
    }

    // MARK: - Sectors

    /// Whether `angle` belongs to the sector centred on `compass`.
    ///
    /// Half-open, `[centre - 22.5, centre + 22.5)`. A closed test on both ends would let a turn sitting exactly on a
    /// boundary satisfy two adjacent poses at once; a fully open one would leave that angle owned by neither. This
    /// way the eight sectors tile the circle exactly once.
    static func sectorOwns(compass: Double, angle: Double) -> Bool {
        var delta = (angle - compass).truncatingRemainder(dividingBy: 360)
        if delta < -180 { delta += 360 }
        if delta >= 180 { delta -= 360 }
        return delta >= -sectorWidth / 2 && delta < sectorWidth / 2
    }

    // MARK: - Matching

    /// `compassAngle` nil means the centre pose.
    static func matches(yaw: Float, pitch: Float, compassAngle: Double?, factor: Float) -> Bool {
        guard let compass = compassAngle else {
            return abs(yaw) < yawCenterTolerance * factor && abs(pitch) < pitchCenterTolerance * factor
        }
        let turn = turn(yaw: yaw, pitch: pitch)
        guard turn.magnitude >= requiredMagnitude(factor: factor), turn.isWithinRange else { return false }
        return sectorOwns(compass: compass, angle: turn.compassAngle)
    }
}
