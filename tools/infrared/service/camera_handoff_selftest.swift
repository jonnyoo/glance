// Explicit hardware test, outside the offline suite. Run as a signed app with
// the development app's bundle ID, profile, camera entitlement and IR service
// configuration. Uses the approved helper; never reads enrollment/credentials,
// saves images, locks the screen or sends keystrokes. Do not run another camera
// consumer during this test. BRIO video/audio is interrupted by each IR capture.
import Foundation
import AVFoundation

@MainActor final class GlanceSettings {
    static let shared = GlanceSettings()
    var allowContinuityCamera: Bool { false }
    var selectedID: String?
    var defaultCameraID: String? { selectedID }
    var builtInDisplayCameraID: String? { nil }
    var externalDisplayCameraID: String? { nil }
}

@main struct CameraHandoffSelfTest {
    @MainActor static func main() async {
        DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
            print("FAIL: camera handoff test timed out")
            exit(1)
        }
        let camera = CameraManager()
        func colour(_ label: String) async throws {
            let started = ContinuousClock.now
            await camera.start()
            if let error = camera.errorMessage { throw InfraredProbeError.execution(error) }
            guard let input = camera.session.inputs.first as? AVCaptureDeviceInput,
                  !input.device.isContinuityCamera,
                  input.device.uniqueID == GlanceSettings.shared.selectedID else {
                throw InfraredProbeError.execution("Capture input is not the selected BRIO")
            }
            let deadline = ContinuousClock.now + .seconds(5)
            var previous: UInt64?
            var count = 0
            while ContinuousClock.now < deadline && count < 15 {
                if let frame = camera.currentFrame, frame.capturedAt >= started, frame.id != previous {
                    previous = frame.id
                    count += 1
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            guard count == 15 else {
                throw InfraredProbeError.execution("\(label): only \(count)/15 fresh colour frames")
            }
            print("PASS: \(label): \(count) fresh colour frames")
            await camera.stopAndWait()
            guard camera.currentFrame == nil && !camera.isRunning else {
                throw InfraredProbeError.execution("Stopped camera retained a frame")
            }
        }
        do {
            // The test explicitly permits only this USB BRIO, with no system-
            // default fallback while the camera disappears during IR capture.
            guard let brio = CameraDeviceCatalog.availableDevices().first(where: { $0.name == "Logitech BRIO" }) else {
                throw InfraredProbeError.execution("Logitech BRIO is unavailable; no other camera will be opened")
            }
            GlanceSettings.shared.selectedID = brio.id
            if CommandLine.arguments.contains("--select-only") {
                print("BRIO_ID=" + brio.id)
                exit(0)
            }
            print("Selected camera: Logitech BRIO")
            try await colour("initial startup")
            try await colour("ordinary restart")
            for (index, delay) in [0, 2, 8].enumerated() {
                let cycle = index + 1
                let captureStarted = ContinuousClock.now
                let infrared = try await InfraredServiceManager.capture(allowPermissionPrompt: false)
                _ = try infrared.image()
                print("PASS: IR capture \(cycle): \(infrared.frames ?? 0) complete frames in \(captureStarted.duration(to: .now))")
                // Mirror the unlock cycle's final stop and later hover/retry.
                camera.stop()
                try await Task.sleep(for: .seconds(delay))
                try await colour("after IR capture \(cycle), idle \(delay)s")
            }
            // Stop while startRunning is queued/in progress, then start again.
            let pending = Task { await camera.start() }
            try await Task.sleep(for: .milliseconds(10))
            camera.stop()
            await pending.value
            await camera.stopAndWait()
            guard camera.currentFrame == nil && !camera.isRunning else {
                throw InfraredProbeError.execution("Cancelled startup published a frame")
            }
            try await colour("after cancelled startup")
            print("PASS: repeated colour/IR handoffs and cancelled-start recovery")
            exit(0)
        } catch {
            await camera.stopAndWait()
            print("FAIL:", error.localizedDescription)
            exit(1)
        }
    }
}
