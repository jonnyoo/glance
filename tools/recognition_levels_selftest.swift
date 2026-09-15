//
//  recognition_levels_selftest.swift
//  glance (tools)
//
//  Offline test for the Recognition slider stops. This project has no test
//  target, so this compiles as a standalone script against the real file:
//
//      swiftc -O -o /tmp/recognition_levels_selftest \
//        glance/Settings/RecognitionLevels.swift \
//        tools/recognition_levels_selftest.swift \
//      && /tmp/recognition_levels_selftest
//
//  `GlanceSettings` takes its fresh-install defaults from `.standard`, so
//  what matters here is (1) the stops never loosen the gate an untouched
//  install already ran, and (2) which stop the knob shows for every value
//  an install could have stored — `nearest(to:)` only snaps the display,
//  the stored value keeps being enforced until the user picks a stop.
//

import Foundation

@main
struct RecognitionLevelsSelfTest {
    nonisolated(unsafe) static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        print("\(condition ? "PASS" : "FAIL")  \(message)")
        if !condition { failures += 1 }
    }

    static func main() {
        // MARK: Match confidence

        // Every never-adjusted install has matched at 0.66 since 0acf68b.
        // Anything lower as the default loosens matching for all of them.
        check(MatchConfidenceLevel.standard.threshold == Float(0.66),
              "match .standard is 0.66 (the gate untouched installs already run)")
        check(MatchConfidenceLevel.lessStrict.threshold == Float(0.58), "match .lessStrict stays 0.58")
        check(MatchConfidenceLevel.moreStrict.threshold == Float(0.68), "match .moreStrict stays 0.68")
        check(MatchConfidenceLevel.lessStrict.threshold < MatchConfidenceLevel.standard.threshold
              && MatchConfidenceLevel.standard.threshold < MatchConfidenceLevel.moreStrict.threshold,
              "match stops strictly increase left to right")

        // Stored values: current stops, d0d2cf2's short-lived 0.63 Default,
        // and c1cca80's 0.62/0.66/0.70 stops that shipped before d0d2cf2.
        let matchRows: [(stored: Float, expected: MatchConfidenceLevel)] = [
            (0.58, .lessStrict),
            (0.62, .lessStrict),
            // Shows Default but still enforces 0.63; see `nearest(to:)`.
            (0.63, .standard),
            (0.66, .standard),
            (0.68, .moreStrict),
            (0.70, .moreStrict),
        ]
        for row in matchRows {
            let got = MatchConfidenceLevel.nearest(to: row.stored)
            check(got == row.expected,
                  "match stored \(row.stored) -> \(got.title) [index \(Int(got.sliderIndex))]")
        }

        for level in MatchConfidenceLevel.allCases {
            check(MatchConfidenceLevel.from(sliderIndex: level.sliderIndex) == level
                  && MatchConfidenceLevel.nearest(to: level.threshold) == level,
                  "match \(level.title) round-trips through slider index and nearest stop")
        }

        // MARK: Detection distance

        check(DetectionDistanceLevel.standard.minimumFaceWidth == Float(0.19),
              "distance .standard is 0.19 (cd1e42e's intended default)")
        check(DetectionDistanceLevel.close.minimumFaceWidth > DetectionDistanceLevel.standard.minimumFaceWidth
              && DetectionDistanceLevel.standard.minimumFaceWidth > DetectionDistanceLevel.far.minimumFaceWidth,
              "distance stops strictly decrease left to right")

        // Current stops plus the older 0.25/0.21/0.17 and 0.24/0.20/0.17
        // stops. 0.21 and 0.17 sit exactly between two current stops, so
        // they resolve by Float32 rounding / first-case tie-break; pinned
        // here so a future change to `nearest` cannot flip them unnoticed.
        let distanceRows: [(stored: Float, expected: DetectionDistanceLevel)] = [
            (0.25, .close),
            (0.24, .close),
            (0.23, .close),
            (0.21, .standard),
            (0.20, .standard),
            (0.19, .standard),
            (0.17, .standard),
            (0.15, .far),
        ]
        for row in distanceRows {
            let got = DetectionDistanceLevel.nearest(to: row.stored)
            check(got == row.expected,
                  "distance stored \(row.stored) -> \(got.title) [index \(Int(got.sliderIndex))]")
        }

        for level in DetectionDistanceLevel.allCases {
            check(DetectionDistanceLevel.from(sliderIndex: level.sliderIndex) == level
                  && DetectionDistanceLevel.nearest(to: level.minimumFaceWidth) == level,
                  "distance \(level.title) round-trips through slider index and nearest stop")
        }

        // Out-of-range slider indices fall back to Default rather than crashing.
        check(MatchConfidenceLevel.from(sliderIndex: 7) == .standard
              && DetectionDistanceLevel.from(sliderIndex: -1) == .standard,
              "out-of-range slider index falls back to .standard")

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
