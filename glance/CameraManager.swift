//
//  CameraManager.swift
//  glance
//
//  Milestone A: owns the AVCaptureSession and publishes the newest camera
//  frame as a CGImage. Runs entirely on-device — no network involved.
//

@preconcurrency import AVFoundation
import CoreImage
import Observation

enum CameraPermission {
    case notDetermined
    case granted
    case denied
}

/// The newest camera frame, in both the downscaled form Vision detection
/// runs on and the native-resolution source it was derived from. `source`
/// is a `CIImage` — Core Image's lazy recipe representation, not rendered
/// pixels — so holding onto it costs nothing until something actually
/// renders from it via `CameraManager.renderCrop`.
struct CameraFrame {
    let id: UInt64
    let image: CGImage
    let source: CIImage
    let sourceSize: CGSize
}

@Observable
@MainActor
final class CameraManager: NSObject {
    private(set) var permission: CameraPermission = .notDetermined
    private(set) var isRunning: Bool = false
    private(set) var currentFrame: CameraFrame?
    private(set) var errorMessage: String?

    /// Exposed read-only so `CameraPreviewView` can attach an
    /// `AVCaptureVideoPreviewLayer` to the same session this manager drives.
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
        // `.high` is a relative "good enough for video" preset, not
        // guaranteed to be the sensor's actual maximum — several
        // webcams/Continuity Camera resolve it well below their real max.
        // Unlike iOS, macOS's `AVCaptureSession` doesn't have an
        // `.inputPriority` preset (it isn't available on this platform) and
        // doesn't fight an explicitly-set `AVCaptureDevice.activeFormat`
        // the way iOS's session-preset system does, so leaving this at
        // `.high` and separately locking the device onto its highest-
        // resolution format in `selectHighestResolutionFormat` below is
        // sufficient here — no preset override needed.
        session.sessionPreset = .high

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(framePublisher, queue: sessionQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        session.commitConfiguration()
    }

    /// Attaches whatever `CameraDeviceCatalog` currently resolves to,
    /// replacing the existing input if the user's camera preference changed
    /// in Settings since this session was last configured. Called on every
    /// `start()` (not just the first), so switching the preferred camera
    /// takes effect the next time a scan starts rather than needing an app
    /// restart. A no-op if the resolved device hasn't changed.
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

    /// Locks the device onto its highest-resolution capture format,
    /// regardless of frame rate — a lock-screen scan doesn't need high fps,
    /// and the *working* frame Vision runs on is still downscaled to
    /// `FramePublisher.maxLongEdge` (640px) right after capture, so this
    /// only changes what `CameraFrame.source` (and therefore `renderCrop`)
    /// actually has to work with. Only takes effect because
    /// `configureSessionIfNeeded` sets `sessionPreset = .inputPriority` —
    /// under any other preset, AVCaptureSession would silently override
    /// this back down.
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

    fileprivate func publish(frame: CameraFrame) {
        currentFrame = frame
    }

    /// Renders a native-resolution crop of `imageRect` (in `frame.image`'s
    /// top-left/y-down pixel space — the same space as `DetectedFace
    /// .boundingBox`) from the undownscaled `frame.source`. Used by spoof-cue
    /// extraction, which needs pixel detail the 640px working frame throws
    /// away (screen texture, moiré, gloss). `nonisolated` and `static` so it
    /// can be called from the same background tasks that already do
    /// Vision/recognition work, without hopping back to the main actor.
    nonisolated static func renderCrop(from frame: CameraFrame, imageRect: CGRect, maxEdge: CGFloat = 448) -> CGImage? {
        let workingWidth = CGFloat(frame.image.width)
        let workingHeight = CGFloat(frame.image.height)
        guard workingWidth > 0, workingHeight > 0 else { return nil }
        let scaleX = frame.sourceSize.width / workingWidth
        let scaleY = frame.sourceSize.height / workingHeight

        // Expand ~1.3x for context around the face — device edges/bezels
        // sit just outside a tight face box, and the extra margin gives the
        // texture/moiré cues real surrounding pixels to sample.
        let expanded = imageRect.insetBy(dx: -imageRect.width * 0.15, dy: -imageRect.height * 0.15)

        // `imageRect` is top-left/y-down (matching `DetectedFace
        // .boundingBox`); Core Image's coordinate space is bottom-left/y-up.
        // Same flip as `FaceDetector.convertToImageSpace`, applied in reverse.
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

    /// Shared across calls — a `CIContext` is expensive to create and safe
    /// to reuse concurrently (it's `Sendable`). `nonisolated`: a `static
    /// let` on this `@MainActor` class is otherwise itself main-actor-
    /// isolated by default, which `renderCrop` (deliberately `nonisolated`
    /// so it can run from the background tasks that already do Vision/
    /// recognition work) can't touch.
    private nonisolated static let cropRenderContext = CIContext()

    /// Sample-buffer callbacks arrive on `sessionQueue`, off the main actor.
    /// This tiny delegate does the CGImage conversion there, then hops back
    /// to the MainActor-isolated manager to publish the result.
    private final class FramePublisher: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
        weak var owner: CameraManager?
        private let ciContext = CIContext()
        /// Detection/embedding only ever need a modest-resolution frame —
        /// running Vision on the full sensor resolution (often 1080p+) is
        /// pure waste. This only affects the `image` half of `CameraFrame`
        /// (used for detection); the live preview renders from the capture
        /// session directly via `AVCaptureVideoPreviewLayer` and is
        /// unaffected. The undownscaled `source` is kept alongside it for
        /// callers that need native-resolution pixels (see `renderCrop`).
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
            guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }

            nextFrameID &+= 1
            let frame = CameraFrame(
                id: nextFrameID,
                image: cgImage,
                source: sourceImage,
                sourceSize: sourceExtent.size
            )

            Task { @MainActor [weak owner] in
                owner?.publish(frame: frame)
            }
        }
    }
}
