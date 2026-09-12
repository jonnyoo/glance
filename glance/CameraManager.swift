//
//  CameraManager.swift
//  glance
//
//  Owns the AVCaptureSession and publishes the newest camera frame as a CGImage. Runs entirely on-device.
//

@preconcurrency import AVFoundation
import CoreImage
import Observation

enum CameraPermission {
    case notDetermined
    case granted
    case denied
}

/// `source` is a `CIImage` — a lazy recipe, not rendered pixels — so holding onto it costs nothing until `renderCrop` uses it.
struct CameraFrame {
    let id: UInt64
    let image: CGImage
    let source: CIImage
    let sourceSize: CGSize
    /// The working frame *before* `LowLightEnhancer`, for anything that must judge what the sensor really saw rather
    /// than what we brightened — the liveness deny cues. Identical to `image` whenever no enhancement was applied.
    var rawImage: CGImage
    /// Mean luma of the raw working frame (before any enhancement), 0…1 — see `SceneLuminance`. 1 if unmeasurable.
    var meanLuminance: Float = 1
    /// True when `image` had `LowLightEnhancer` applied; `source` and `rawImage` are always ungained.
    var isLowLightEnhanced: Bool = false
}

@Observable
@MainActor
final class CameraManager: NSObject {
    private(set) var permission: CameraPermission = .notDetermined
    private(set) var isRunning: Bool = false
    private(set) var currentFrame: CameraFrame?
    private(set) var errorMessage: String?
    /// Advisory only — never gates a scan. `errorMessage` means "no usable camera"; this means "the camera works, but
    /// something optional didn't apply". Surfaced by Settings/Face Lab, ignored by the unlock path.
    private(set) var frameRateNote: String?

    /// Exposed read-only so `CameraPreviewView` can attach a preview layer to the same session.
    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let sessionQueue = DispatchQueue(label: "com.jonathan.glance.camera.session")

    /// Handed to the delegate outside the actor; only ever touched via `Task { @MainActor ... }`.
    private let framePublisher = FramePublisher()

    override init() {
        super.init()
        framePublisher.owner = self
    }

    func start() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            permission = .granted
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            permission = granted ? .granted : .denied
        default:
            permission = .denied
        }

        guard permission == .granted else {
            errorMessage = "Camera access not granted (status: \(describe(status))). " +
                (status == .restricted
                    ? "macOS reports this as *restricted* — not a simple user denial. This usually means Screen Time content restrictions or an MDM/profile policy is blocking camera access for this app; toggling it in System Settings > Privacy & Security > Camera won't help until that restriction is lifted."
                    : "Enable it in System Settings > Privacy & Security > Camera. If glance isn't listed there, quit the app, run `tccutil reset Camera com.jonathan.glance` in Terminal, then relaunch so macOS asks again.")
            return
        }

        errorMessage = nil
        configureSessionIfNeeded()
        reconcileDeviceIfNeeded()
        // After reconcile, not inside it: `reconcileDeviceIfNeeded` early-returns when the device is unchanged, so folding
        // this in there would leave the frame-rate policy stuck at whatever Night Boost was set to on the first scan.
        applyFrameRatePolicy()

        sessionQueue.async { [session] in
            if !session.isRunning {
                session.startRunning()
            }
        }
        isRunning = true
    }

    func stop() {
        sessionQueue.async { [session] in
            if session.isRunning {
                session.stopRunning()
            }
        }
        isRunning = false
        currentFrame = nil
    }

    private func describe(_ status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "notDetermined"
        case .restricted: return "restricted"
        case .denied: return "denied"
        case .authorized: return "authorized"
        @unknown default: return "unknown(\(status.rawValue))"
        }
    }

    private var isConfigured = false
    private var currentInput: AVCaptureDeviceInput?

    private func configureSessionIfNeeded() {
        guard !isConfigured else { return }
        isConfigured = true

        session.beginConfiguration()
        // `.high` doesn't guarantee the sensor's max resolution; macOS (unlike iOS) doesn't fight an explicitly-set
        // `activeFormat`, so leaving this at `.high` and locking the format separately below is sufficient.
        session.sessionPreset = .high

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(framePublisher, queue: sessionQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        session.commitConfiguration()
    }

    /// Called on every `start()` so a camera preference change in Settings takes effect without an app restart.
    private func reconcileDeviceIfNeeded() {
        guard let device = CameraDeviceCatalog.resolvedDevice() else {
            errorMessage = "No camera device found."
            return
        }
        guard device.uniqueID != currentInput?.device.uniqueID else { return }

        session.beginConfiguration()
        if let currentInput {
            session.removeInput(currentInput)
        }
        if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
            session.addInput(input)
            currentInput = input
            selectHighestResolutionFormat(for: device)
        } else {
            currentInput = nil
            errorMessage = "No camera device found."
        }
        session.commitConfiguration()
    }

    /// Highest resolution regardless of fps — Vision still works from the downscaled frame; this only affects
    /// what `CameraFrame.source` (and therefore `renderCrop`) has to work with.
    private func selectHighestResolutionFormat(for device: AVCaptureDevice) {
        let best = device.formats.max { lhs, rhs in
            let l = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
            let r = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
            return Int(l.width) * Int(l.height) < Int(r.width) * Int(r.height)
        }
        guard let best else { return }
        do {
            try device.lockForConfiguration()
            device.activeFormat = best
            device.unlockForConfiguration()
        } catch {
            errorMessage = "Couldn't select the camera's highest-resolution format: \(error.localizedDescription)"
        }
    }

    /// The built-in camera pins itself to 30 fps (min == max frame duration on every format this Mac reports), which caps
    /// its auto-exposure at ~33 ms and is why a dark room arrives as noise. With Night Boost on, raising only the *max*
    /// frame duration to 1/15 s lets the ISP drop to 15 fps and double the exposure when — and only when — the scene is
    /// dark; a lit room stays at 30 fps. With it off, the max is pinned back to the format's own floor so the setting takes
    /// effect on the next scan rather than the next launch. Re-applied on every `start()` since setting `activeFormat`
    /// resets both durations.
    private func applyFrameRatePolicy() {
        guard let device = currentInput?.device else { return }
        let slowest = CMTime(value: 1, timescale: 15)
        let canSlowDown = device.activeFormat.videoSupportedFrameRateRanges.contains {
            CMTimeCompare($0.maxFrameDuration, slowest) >= 0
        }
        // `.invalid` means "your own default" to AVCaptureDevice. Computing a concrete off-value instead would pin the
        // device to whatever that value was — on a 60 fps webcam, switching Night Boost off would lock it at 60 fps.
        let target = (GlanceSettings.shared.nightBoostEnabled && canSlowDown) ? slowest : CMTime.invalid
        guard CMTimeCompare(device.activeVideoMaxFrameDuration, target) != 0 else { return }

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            // Order matters: max must never sit below min, so widen from the min side first.
            if target.isValid, CMTimeCompare(target, device.activeVideoMinFrameDuration) < 0 {
                device.activeVideoMinFrameDuration = target
            }
            device.activeVideoMaxFrameDuration = target
        } catch {
            // Genuinely non-fatal, so it must NOT reach `errorMessage`: `FaceUnlockCoordinator.runScanCycle` aborts the
            // whole scan on any non-nil `errorMessage`, so reporting a failed frame-rate hint there would disable face
            // unlock entirely whenever another app (FaceTime, Zoom) holds the device's configuration lock.
            frameRateNote = "Couldn't set the camera's low-light frame rate: \(error.localizedDescription)"
        }
    }

    fileprivate func publish(frame: CameraFrame) {
        currentFrame = frame
    }

    /// Renders a native-resolution crop of `imageRect` from `frame.source`, for spoof-cue extraction which
    /// needs pixel detail (screen texture, moiré, gloss) the downscaled working frame throws away.
    nonisolated static func renderCrop(from frame: CameraFrame, imageRect: CGRect, maxEdge: CGFloat = 448) -> CGImage? {
        let workingWidth = CGFloat(frame.image.width)
        let workingHeight = CGFloat(frame.image.height)
        guard workingWidth > 0, workingHeight > 0 else { return nil }
        let scaleX = frame.sourceSize.width / workingWidth
        let scaleY = frame.sourceSize.height / workingHeight

        // Expand ~1.3x so device edges/bezels are captured for texture/moiré cues.
        let expanded = imageRect.insetBy(dx: -imageRect.width * 0.15, dy: -imageRect.height * 0.15)

        // Flip from `imageRect`'s top-left/y-down space to Core Image's bottom-left/y-up (reverse of FaceDetector.convertToImageSpace).
        let nativeX = expanded.origin.x * scaleX
        let nativeWidth = expanded.width * scaleX
        let nativeHeight = expanded.height * scaleY
        let nativeY = frame.sourceSize.height - (expanded.origin.y + expanded.height) * scaleY
        var nativeRect = CGRect(x: nativeX, y: nativeY, width: nativeWidth, height: nativeHeight)

        let sourceExtent = CGRect(origin: .zero, size: frame.sourceSize)
        nativeRect = nativeRect.intersection(sourceExtent)
        guard !nativeRect.isEmpty else { return nil }

        var cropped = frame.source.cropped(to: nativeRect)
            .transformed(by: CGAffineTransform(translationX: -nativeRect.minX, y: -nativeRect.minY))
        let longEdge = max(nativeRect.width, nativeRect.height)
        if longEdge > maxEdge {
            let scale = maxEdge / longEdge
            cropped = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        return cropRenderContext.createCGImage(cropped, from: cropped.extent)
    }

    /// `CIContext` is expensive to create and safe to reuse concurrently. Explicitly `nonisolated` since a `static let`
    /// on this `@MainActor` class would otherwise be main-actor-isolated, which the `nonisolated renderCrop` can't touch.
    private nonisolated static let cropRenderContext = CIContext()

    /// Sample-buffer callbacks arrive on `sessionQueue`, off the main actor; this delegate converts there, then hops back.
    private final class FramePublisher: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        weak var owner: CameraManager?
        private let ciContext = CIContext()
        /// Detection only needs a modest resolution; the live preview renders from the capture session directly and
        /// is unaffected. The undownscaled `source` is kept alongside for callers needing native pixels (`renderCrop`).
        private let maxLongEdge: CGFloat = 640
        private var nextFrameID: UInt64 = 0

        func captureOutput(
            _ output: AVCaptureOutput,
            didOutput sampleBuffer: CMSampleBuffer,
            from connection: AVCaptureConnection
        ) {
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
            let sourceExtent = sourceImage.extent
            var ciImage = sourceImage
            let longEdge = max(ciImage.extent.width, ciImage.extent.height)
            if longEdge > maxLongEdge {
                let scale = maxLongEdge / longEdge
                ciImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }

            // Night boost: measure the raw working frame, then gain it up if the room is dark. The native `source`
            // stays untouched so the glare cue keeps reading real sensor highlights (see LowLightEnhancer.swift).
            let meanLuminance = SceneLuminance.meanLuminance(of: ciImage, context: ciContext) ?? 1
            let enhanced = LowLightEnhancer.enhance(ciImage, meanLuminance: meanLuminance)
            let isEnhanced = enhanced !== ciImage
            guard let cgImage = ciContext.createCGImage(enhanced, from: enhanced.extent) else { return }
            // Second render only in a dark room: the bezel deny cue reads this, and gain applied to a dark frame can
            // invent or erase the rectangle edges it keys on (LivenessFeatures.swift feeds it the working frame).
            let rawCGImage = isEnhanced ? (ciContext.createCGImage(ciImage, from: ciImage.extent) ?? cgImage) : cgImage

            nextFrameID &+= 1
            let frame = CameraFrame(
                id: nextFrameID,
                image: cgImage,
                source: sourceImage,
                sourceSize: sourceExtent.size,
                rawImage: rawCGImage,
                meanLuminance: meanLuminance,
                isLowLightEnhanced: isEnhanced
            )

            Task { @MainActor [weak owner] in
                owner?.publish(frame: frame)
            }
        }
    }
}
