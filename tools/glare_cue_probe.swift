//
//  glare_cue_probe.swift
//  glance (tools)
//
//  Standalone calibration probe for the gloss/glare cue
//  (`GlareCue.swift` / `GlareCueExtractor.swift`): loads image files from
//  disk and prints the raw `GlareSample` for each, plus the cue level those
//  numbers produce — no camera, no Vision, no face detection involved.
//  `GlareCueExtractor` only needs CoreGraphics, which is exactly why it's
//  kept separate from LivenessFeatures.swift's Vision-facing extraction, so
//  this tool can run against a folder of real-vs-screen stills to pick a
//  real `LivenessTuning.glossLevel`.
//
//  Build and run:
//
//      swiftc -O -o /tmp/glare_cue_probe \
//        glance/Liveness/GlareCue.swift \
//        glance/Liveness/GlareCueExtractor.swift \
//        glance/Liveness/LivenessCues.swift \
//        glance/Liveness/LivenessScoring.swift \
//        glance/Liveness/LandmarkGeometry.swift \
//        glance/Liveness/GeometryLiveness.swift \
//        tools/glare_cue_probe.swift \
//      && /tmp/glare_cue_probe path/to/live1.jpg path/to/screen1.jpg ...
//
//  Each argument is a path to an already-cropped-around-the-face image —
//  crop by hand (or point it at frames saved from Face Lab) to roughly
//  match what `CameraManager.renderCrop` hands the real extractor: a
//  native-resolution crop with a little margin around the face, not the
//  full camera frame. Pass a live sample and a spoof sample side by side:
//  the `cue level` row is the number `LivenessTuning.glossLevel` is
//  compared against, so put the gate somewhere in the gap between the two
//  columns.
//

import Foundation
import CoreGraphics
import ImageIO

@main
struct GlareCueProbe {
    static func main() {
        let paths = CommandLine.arguments.dropFirst()
        guard !paths.isEmpty else {
            print("Usage: glare_cue_probe <image1> <image2> ...")
            print("Prints the GlareSample and resulting cue level for each image.")
            exit(1)
        }

        var rows: [(name: String, sample: GlareSample, level: Float, confidence: Float)] = []
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            else {
                print("Skipping \(path): couldn't load as an image.")
                continue
            }
            guard let sample = GlareCueExtractor.extract(faceCrop: image) else {
                print("Skipping \(path): extraction failed.")
                continue
            }
            // Routed through the real cue function rather than recomputed
            // here, so this can never drift from what the app actually does.
            let frame = LivenessFrame(
                timestamp: Date(), landmarks: [], interocularDistance: nil, yaw: nil,
                leftEyeAspectRatio: nil, rightEyeAspectRatio: nil, noseOffsetRatio: nil,
                hasReliableLandmarks: true, deviceOverlapFraction: nil, glare: sample
            )
            let reading = LivenessCues.glossGlare(frame)
            rows.append((
                name: (path as NSString).lastPathComponent,
                sample: sample, level: reading.level, confidence: reading.confidence
            ))
        }

        guard !rows.isEmpty else {
            print("No images could be processed.")
            exit(1)
        }

        let nameWidth = max(18, (rows.map(\.name.count).max() ?? 4) + 2)
        print("".padding(toLength: nameWidth, withPad: " ", startingAt: 0), terminator: "")
        for row in rows {
            print(row.name.padding(toLength: nameWidth, withPad: " ", startingAt: 0), terminator: "")
        }
        print("")

        func printRow(_ title: String, _ format: String, _ pick: (Int) -> Float) {
            print(title.padding(toLength: nameWidth, withPad: " ", startingAt: 0), terminator: "")
            for index in rows.indices {
                print(String(format: format, pick(index)).padding(toLength: nameWidth, withPad: " ", startingAt: 0), terminator: "")
            }
            print("")
        }

        printRow("crop px", "%.0f") { Float(rows[$0].sample.cropPixelWidth) }
        printRow("specular %", "%.4f") { rows[$0].sample.specularFraction }
        printRow("specular cluster", "%.4f") { rows[$0].sample.specularClusterRatio }
        printRow("cue level", "%.3f") { rows[$0].level }
        printRow("confidence", "%.3f") { rows[$0].confidence }

        print("\nCurrent gate: LivenessTuning.glossLevel = \(LivenessTuning.default.glossLevel) over \(LivenessTuning.default.glossFrames) frames.")
        print("Set it between the live and spoof columns' `cue level` rows, in LivenessCues.swift.")
    }
}
