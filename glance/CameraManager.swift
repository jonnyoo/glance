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
}

@Observable
@MainActor
final class CameraManager: NSObject {
    private(set) var permission: CameraPermission = .notDetermined
    private(set) var isRunning: Bool = false
    private(set) var currentFrame: CameraFrame?
    private(set) var errorMessage: String?

    /// Exposed read-only so `CameraPreviewView` can attach a preview layer to the same session.
    var session: AVCaptureSession { sessionWorker.session }
    private let sessionWorker = SessionWorker()

    /// Handed to the delegate outside the actor; coalesces frame delivery back onto `@MainActor`.
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

        guard let device = CameraDeviceCatalog.resolvedDevice() else {
            errorMessage = "No camera device found."
            isRunning = false
            return
        }

        errorMessage = nil
        let worker = sessionWorker
        let publisher = framePublisher
        let startError: String? = await withCheckedContinuation { continuation in
            worker.start(device: device, delegate: publisher) { error in
                continuation.resume(returning: error)
            }
        }
        if let startError {
            errorMessage = startError
            isRunning = false
        } else {
            isRunning = true
        }
    }

    func stop() {
        framePublisher.clearPending()
        sessionWorker.stop()
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

    fileprivate func publish(frame: CameraFrame) {
        guard isRunning else { return }
        currentFrame = frame
    }

    /// Serializes all `AVCaptureSession` configuration, device switching, format selection, and
    /// `startRunning()`/`stopRunning()` calls on `queue` so they never race `@MainActor`.
    private nonisolated final class SessionWorker: @unchecked Sendable {
        let session = AVCaptureSession()
        private let videoOutput = AVCaptureVideoDataOutput()
        private let queue = DispatchQueue(label: "com.jonathan.glance.camera.session")
        private var isConfigured = false
        private var currentInput: AVCaptureDeviceInput?

        func start(
            device: AVCaptureDevice,
            delegate: AVCaptureVideoDataOutputSampleBufferDelegate,
            completion: @escaping @Sendable (String?) -> Void
        ) {
            queue.async { [self] in
                configureSessionIfNeeded(delegate: delegate)
                if let error = reconcileDeviceIfNeeded(device) {
                    completion(error)
                    return
                }
                if !session.isRunning {
                    session.startRunning()
                }
                completion(nil)
            }
        }

        func stop() {
            queue.async { [self] in
                if session.isRunning {
                    session.stopRunning()
                }
            }
        }

        private func configureSessionIfNeeded(delegate: AVCaptureVideoDataOutputSampleBufferDelegate) {
            guard !isConfigured else { return }
            isConfigured = true

            session.beginConfiguration()
            // `.high` doesn't guarantee the sensor's max resolution; macOS (unlike iOS) doesn't fight an explicitly-set
            // `activeFormat`, so leaving this at `.high` and locking the format separately below is sufficient.
            session.sessionPreset = .high

            videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.setSampleBufferDelegate(delegate, queue: queue)
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
            }

            session.commitConfiguration()
        }

        private func reconcileDeviceIfNeeded(_ device: AVCaptureDevice) -> String? {
            guard device.uniqueID != currentInput?.device.uniqueID else { return nil }

            var configError: String?
            session.beginConfiguration()
            if let currentInput {
                session.removeInput(currentInput)
            }
            if let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) {
                session.addInput(input)
                currentInput = input
                selectBestStreamingFormat(for: device)
            } else {
                currentInput = nil
                configError = "No camera device found."
            }
            session.commitConfiguration()
            return configError
        }

        /// Picks the highest-resolution format (up to 4K) that still sustains video frame rates (>= 24fps)
        /// so blink and 3D motion liveness cues aren't starved by a 5fps still-photo mode.
        private func selectBestStreamingFormat(for device: AVCaptureDevice) {
            let maxPixels = 3840 * 2160
            let streamingCandidates = device.formats.filter { format in
                let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                let pixels = Int(dims.width) * Int(dims.height)
                let maxFPS = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
                return maxFPS >= 24.0 && pixels <= maxPixels
            }
            let pool = streamingCandidates.isEmpty ? device.formats : streamingCandidates
            let best = pool.max { lhs, rhs in
                let l = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
                let r = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
                return Int(l.width) * Int(l.height) < Int(r.width) * Int(r.height)
            }
            guard let best else { return }
            if (try? device.lockForConfiguration()) != nil {
                device.activeFormat = best
                device.unlockForConfiguration()
            }
        }
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

    /// Sample-buffer callbacks arrive on `SessionWorker.queue`, off the main actor; this delegate converts there
    /// and coalesces delivery so at most one `CVPixelBuffer`-backed `CameraFrame` is ever queued for `@MainActor`.
    private nonisolated final class FramePublisher: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
        @MainActor weak var owner: CameraManager?
        private let ciContext = CIContext()
        /// Detection only needs a modest resolution; the live preview renders from the capture session directly and
        /// is unaffected. The undownscaled `source` is kept alongside for callers needing native pixels (`renderCrop`).
        private let maxLongEdge: CGFloat = 640
        private var nextFrameID: UInt64 = 0

        private let pendingLock = NSLock()
        private var pendingFrame: CameraFrame?
        private var isDeliveryScheduled = false

        func clearPending() {
            pendingLock.lock()
            pendingFrame = nil
            pendingLock.unlock()
        }

        private func enqueue(_ frame: CameraFrame) -> Bool {
            pendingLock.lock()
            defer { pendingLock.unlock() }
            pendingFrame = frame
            guard !isDeliveryScheduled else { return false }
            isDeliveryScheduled = true
            return true
        }

        private func takePending() -> CameraFrame? {
            pendingLock.lock()
            defer { pendingLock.unlock() }
            let latest = pendingFrame
            pendingFrame = nil
            isDeliveryScheduled = false
            return latest
        }

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

            guard enqueue(frame) else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let latest = self.takePending() {
                    self.owner?.publish(frame: latest)
                }
            }
        }
    }
}
