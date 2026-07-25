//
//  LivenessMonitor.swift
//  glance
//
//  Basic anti-spoofing: requires a short run of confident matches PLUS
//  natural micro-motion in head pose before accepting a "live" verdict.
//  This defeats a static printed photo held up to the camera — a print
//  doesn't move at all between frames, so its pose signal is unnaturally
//  flat, while a live face always has tiny continuous jitter (breathing,
//  handheld camera, involuntary micro-movement).
//
//  This does NOT defeat a video replay or a phone/tablet screen showing a
//  moving face — those exhibit exactly the kind of natural motion this
//  checks for. A MacBook webcam has no depth sensor, so this is
//  fundamentally weaker than iPhone Face ID's liveness guarantees. That
//  matters here specifically because a successful spoof types the real
//  macOS password — this limitation should stay visible in the unlock UI,
//  not just this comment.
//

import Foundation

struct LivenessSample {
    let timestamp: Date
    let yaw: Float?
    /// Similarity of this frame's match against the enrolled identity —
    /// liveness only matters once we already think we recognize someone.
    let matchSimilarity: Float
}

enum LivenessVerdict: Equatable {
    /// Not enough samples in the window yet to decide either way.
    case insufficientData
    case notLive(reason: String)
    case live
}

@MainActor
final class LivenessMonitor {
    private let windowDuration: TimeInterval
    private let minSamplesRequired: Int
    /// Every sample in the window must clear this similarity — liveness
    /// checking only makes sense once matches are already confident;
    /// tracks the caller's own recognition threshold rather than
    /// duplicating that decision here.
    private let matchThreshold: Float
    /// Standard deviation of yaw (radians) below this is "suspiciously
    /// static" — the core photo-detection signal. Empirical/tunable: small
    /// enough that ordinary human stillness (which always has some
    /// involuntary micro-jitter) clears it easily.
    private let minYawVariation: Float
    /// Standard deviation above this is "too much motion to trust" — guards
    /// against a rapidly-moved spoof prop, or just an unstable capture.
    private let maxYawVariation: Float

    private var samples: [LivenessSample] = []

    init(
        windowDuration: TimeInterval = 1.0,
        minSamplesRequired: Int = 5,
        matchThreshold: Float,
        minYawVariation: Float = 0.003,
        maxYawVariation: Float = 0.5
    ) {
        self.windowDuration = windowDuration
        self.minSamplesRequired = minSamplesRequired
        self.matchThreshold = matchThreshold
        self.minYawVariation = minYawVariation
        self.maxYawVariation = maxYawVariation
    }

    func reset() {
        samples.removeAll()
    }

    /// Feeds one processed frame's result into the rolling window and
    /// returns the current liveness verdict. Call once per frame the
    /// caller considers a candidate match.
    @discardableResult
    func observe(yaw: Float?, matchSimilarity: Float) -> LivenessVerdict {
        let now = Date()
        samples.append(LivenessSample(timestamp: now, yaw: yaw, matchSimilarity: matchSimilarity))
        samples.removeAll { now.timeIntervalSince($0.timestamp) > windowDuration }
        return evaluate()
    }

    private func evaluate() -> LivenessVerdict {
        guard samples.count >= minSamplesRequired else { return .insufficientData }

        guard samples.allSatisfy({ $0.matchSimilarity >= matchThreshold }) else {
            return .notLive(reason: "Match confidence dropped during the check.")
        }

        let yaws = samples.compactMap(\.yaw)
        guard yaws.count == samples.count else {
            return .notLive(reason: "Head pose not detected consistently.")
        }

        let stdDev = Self.standardDeviation(yaws)
        if stdDev < minYawVariation {
            return .notLive(reason: "No natural head motion detected — possible static photo.")
        }
        if stdDev > maxYawVariation {
            return .notLive(reason: "Motion too erratic to confirm a stable match.")
        }

        return .live
    }

    private static func standardDeviation(_ values: [Float]) -> Float {
        guard values.count > 1 else { return 0 }
        let mean = values.reduce(0, +) / Float(values.count)
        let variance = values.reduce(Float(0)) { $0 + ($1 - mean) * ($1 - mean) } / Float(values.count)
        return variance.squareRoot()
    }
}
