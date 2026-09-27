import AVFoundation
// Explicit BRIO-only hardware regression, outside the offline suite.
// Compares rectangular and outlined glare on identical in-memory frames;
// emits numeric summaries only. No enrollment, passwords or real keystrokes.
// Compile with -default-isolation MainActor, CameraManager, CameraDeviceCatalog,
// FaceDetector, FaceAligner and all Liveness sources. Use the signed package
// setup of camera_handoff_selftest.swift and launch through Launch Services.
import Foundation
import Vision

@MainActor final class GlanceSettings {
  static let shared = GlanceSettings()
  let allowContinuityCamera = false
  var selectedID: String?
  var defaultCameraID: String? { selectedID }
  var builtInDisplayCameraID: String? { nil }
  var externalDisplayCameraID: String? { nil }
}
nonisolated struct FaceRecognitionResult {
  let face: DetectedFace
  let alignmentTier: AlignmentTier
}
@main struct Parity {
  @MainActor static func main() async {
    DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
      print("FAIL: timeout")
      exit(1)
    }
    let camera = CameraManager()
    do {
      guard
        let brio = CameraDeviceCatalog.availableDevices().first(where: {
          $0.name == "Logitech BRIO"
        })
      else { throw NSError(domain: "BRIO unavailable", code: 1) }
      GlanceSettings.shared.selectedID = brio.id
      let full = LivenessAnalyzer()
      let fast = LivenessAnalyzer(skipAbstainingGeometry: true)
      full.modeProvider = { .heavy }
      fast.modeProvider = { .heavy }
      await camera.start()
      guard let input = camera.session.inputs.first as? AVCaptureDeviceInput,
        input.device.uniqueID == brio.id, !input.device.isContinuityCamera
      else { throw NSError(domain: "Wrong camera", code: 2) }
      let deadline = ContinuousClock.now + .seconds(7)
      var previous: UInt64?
      var compared = 0
      var glareFrames = 0
      var correctedGlareFrames = 0
      var mismatches = 0
      var correctedMax: Float = 0
      var minGlare: Float = 1
      var maxGlare: Float = 0
      var maxBlink: Float = 0
      while ContinuousClock.now < deadline {
        guard let frame = camera.currentFrame, frame.id != previous else {
          try await Task.sleep(for: .milliseconds(10))
          continue
        }
        previous = frame.id
        let timestamp = Date()
        let results = try await Task.detached(priority: .userInitiated) { () -> [LivenessFrame] in
          var output = [LivenessFrame]()
          for quality in [true, false] {
            let faces = try FaceDetector.detectFaces(in: frame.image, includeQuality: quality)
            guard
              let face = faces.max(by: {
                $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width
                  * $1.boundingBox.height
              }), let aligned = FaceAligner.align(face, from: frame.image)
            else { return [] }
            let result = FaceRecognitionResult(face: face, alignmentTier: aligned.tier)
            let crop = CameraManager.renderCrop(from: frame, imageRect: face.boundingBox)
            let current = LivenessFeatureExtractor.extract(
              from: result, frame: frame.image, faceCrop: crop, timestamp: timestamp)
            if quality {
              output.append(
                LivenessFrame(
                  timestamp: current.timestamp, landmarks: current.landmarks,
                  interocularDistance: current.interocularDistance, yaw: current.yaw,
                  leftEyeAspectRatio: current.leftEyeAspectRatio,
                  rightEyeAspectRatio: current.rightEyeAspectRatio,
                  noseOffsetRatio: current.noseOffsetRatio,
                  hasReliableLandmarks: current.hasReliableLandmarks,
                  deviceOverlapFraction: current.deviceOverlapFraction,
                  glare: crop.flatMap { GlareCueExtractor.extract(faceCrop: $0) }))
            } else {
              output.append(current)
            }
          }
          return output
        }.value
        if results.count == 2 {
          let a = full.observe(results[0])
          let b = fast.observe(results[1])
          if LivenessCue.allCases.filter({ $0 != .glossGlare }).contains(where: {
            a.cueStates[$0] != b.cueStates[$0]
          }) {
            mismatches += 1
          }
          let glare = LivenessCues.glossGlare(results[0]).level
          minGlare = min(minGlare, glare)
          maxGlare = max(maxGlare, glare)
          let corrected = LivenessCues.glossGlare(results[1]).level
          correctedMax = max(correctedMax, corrected)
          if corrected >= LivenessTuning.default.glossLevel { correctedGlareFrames += 1 }
          if glare >= LivenessTuning.default.glossLevel { glareFrames += 1 }
          maxBlink = max(maxBlink, a.cueStates[.blink]?.reading.level ?? 0)
          compared += 1
        }
        try await Task.sleep(for: .milliseconds(20))
      }
      await camera.stopAndWait()
      print(
        String(
          format:
            "Compared %d fresh BRIO frames; non-glare cue mismatches %d; old glare over gate %d; old glare range %.3f–%.3f; maximum blink %.2f",
          compared, mismatches, glareFrames, minGlare, maxGlare, maxBlink))
      print(
        String(
          format: "Face-outline glare: %d over gate; maximum %.3f", correctedGlareFrames,
          correctedMax))
      guard compared > 0, mismatches == 0 else { exit(1) }
      print("PASS: all other liveness cues identical; no enrollment or password accessed.")
      exit(0)
    } catch {
      await camera.stopAndWait()
      print("FAIL:", error.localizedDescription)
      exit(1)
    }
  }
}
