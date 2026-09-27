import AVFoundation
// Explicit signed hardware test; outside the offline suite. Pin the BRIO,
// compare both detection paths on the same in-memory pixels, and report only
// timings/pass-fail. No enrollment, credentials, saved images or keystrokes.
// Compile with -default-isolation MainActor and CameraManager, CameraDeviceCatalog,
// FaceDetector, FaceAligner and Liveness/LandmarkGeometry. Package/sign as described
// for camera_handoff_selftest.swift, then launch through Launch Services.
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
@main struct QualityBenchmark {
  nonisolated static func seconds(_ d: Duration) -> Double {
    let c = d.components
    return Double(c.seconds) + Double(c.attoseconds) / 1e18
  }
  nonisolated static func points(_ face: DetectedFace) -> [CGPoint] {
    face.landmarks?.allPoints?.normalizedPoints.map { $0 } ?? []
  }
  nonisolated static func equivalent(_ a: [DetectedFace], _ b: [DetectedFace], image: CGImage)
    -> Bool
  {
    guard a.count == b.count else {
      print("Different face counts:", a.count, b.count)
      return false
    }
    return zip(a, b).allSatisfy { lhs, rhs in
      guard lhs.boundingBox == rhs.boundingBox,
        lhs.normalizedBoundingBox == rhs.normalizedBoundingBox,
        lhs.yaw == rhs.yaw, lhs.roll == rhs.roll, lhs.pitch == rhs.pitch,
        points(lhs) == points(rhs), let l = FaceAligner.align(lhs, from: image),
        let r = FaceAligner.align(rhs, from: image), l.tier == r.tier
      else { return false }
      return (l.image.dataProvider?.data as Data?) == (r.image.dataProvider?.data as Data?)
    }
  }
  @MainActor static func main() async {
    DispatchQueue.global().asyncAfter(deadline: .now() + 45) {
      print("FAIL: timed out")
      exit(1)
    }
    let camera = CameraManager()
    do {
      guard
        let device = CameraDeviceCatalog.availableDevices().first(where: {
          $0.name == "Logitech BRIO"
        })
      else { throw NSError(domain: "BRIO unavailable", code: 1) }
      GlanceSettings.shared.selectedID = device.id
      await camera.start()
      guard let input = camera.session.inputs.first as? AVCaptureDeviceInput,
        input.device.uniqueID == device.id, !input.device.isContinuityCamera
      else { throw NSError(domain: "Wrong input", code: 2) }
      var previous: UInt64?
      var totals = [true: 0.0, false: 0.0]
      var faceComparisons = 0
      for index in 0..<12 {
        let deadline = ContinuousClock.now + .seconds(5)
        while (camera.currentFrame == nil || camera.currentFrame?.id == previous)
          && ContinuousClock.now < deadline
        { try await Task.sleep(for: .milliseconds(10)) }
        guard let frame = camera.currentFrame, frame.id != previous else {
          throw NSError(domain: "No fresh BRIO frame", code: 3)
        }
        previous = frame.id
        let stats = try await Task.detached(priority: .userInitiated) {
          () -> (Double, Double, Bool, Int) in
          var timings = [true: 0.0, false: 0.0]
          var faces = [Bool: [DetectedFace]]()
          for include in index % 2 == 0 ? [true, false] : [false, true] {
            let t = ContinuousClock.now
            faces[include] = try FaceDetector.detectFaces(in: frame.image, includeQuality: include)
            timings[include] = seconds(t.duration(to: .now))
          }
          return (
            timings[true]!, timings[false]!,
            equivalent(faces[true]!, faces[false]!, image: frame.image), faces[true]!.count
          )
        }.value
        guard stats.2 else {
          print("Comparison failure; faces:", stats.3)
          throw NSError(domain: "Face equivalence failed", code: 4)
        }
        faceComparisons += stats.3
        if index > 1 {
          totals[true]! += stats.0
          totals[false]! += stats.1
        }
        print(
          String(
            format:
              "Frame %d: quality %.4fs; no quality %.4fs; identical boxes/pose/landmarks/aligned pixels: PASS",
            index + 1, stats.0, stats.1))
      }
      await camera.stopAndWait()
      guard faceComparisons > 0 else {
        throw NSError(domain: "No faces to compare; test is inconclusive", code: 5)
      }
      print(
        String(
          format: "Warm means: quality %.4fs; no quality %.4fs", totals[true]! / 10,
          totals[false]! / 10))
      exit(0)
    } catch {
      await camera.stopAndWait()
      print("FAIL:", error.localizedDescription)
      exit(1)
    }
  }
}
