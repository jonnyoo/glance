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
    let capturedAt: ContinuousClock.Instant
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
    private(set) var session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.jonathan.glance.camera.session")

    private var generation: UInt64 = 0
    // AVCaptureVideoDataOutput does not retain its delegate.
    private var framePublisher: FramePublisher?

    func start() async {
        generation &+= 1
        let request = generation
        isRunning = false
        currentFrame = nil
        // Enqueue retirement before any suspension. A concurrent stop/start
        // cannot let this request's old session stop a newer request's camera.
        retire(session)
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            permission = .granted
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .video)
            guard generation == request, !Task.isCancelled else { return }
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

        guard generation == request, !Task.isCancelled else { return }
        errorMessage = nil
        // Reattaching the USB driver completes before AVFoundation necessarily
        // republishes the BRIO. Wait briefly for the selected device; never
        // substitute another camera while it is absent.
        let deviceDeadline = ContinuousClock.now + .seconds(5)
        var selectedDevice = CameraDeviceCatalog.resolvedDevice()
        while selectedDevice == nil && ContinuousClock.now < deviceDeadline {
            do { try await Task.sleep(for: .milliseconds(200)) }
            catch { return }
            guard generation == request, !Task.isCancelled else { return }
            selectedDevice = CameraDeviceCatalog.resolvedDevice()
        }
        guard generation == request, !Task.isCancelled else { return }
        guard let device = selectedDevice else {
            errorMessage = "The selected camera is unavailable. Reconnect it or choose a camera in Settings."
            return
        }
        // USB IR capture detaches and reattaches the BRIO's drivers. Its
        // uniqueID survives, but the old CMIO input/connection does not.
        // Rebuild the entire stopped pipeline instead of reusing that input.
        let replacement = AVCaptureSession()
        let publisher = FramePublisher(owner: self, generation: request)
        session = replacement
        framePublisher = publisher
        isRunning = true
        let error: String? = await withCheckedContinuation { continuation in
            sessionQueue.async { [sessionQueue] in
                continuation.resume(returning: Self.configureAndStart(
                    replacement, device: device, publisher: publisher, queue: sessionQueue))
            }
        }
        guard generation == request else { return }
        if Task.isCancelled || error != nil {
            stop()
            errorMessage = error
        }
    }

    func stop() {
        generation &+= 1
        isRunning = false
        currentFrame = nil
        retire(session)
        framePublisher = nil
    }

    /// Drain and release AVFoundation's USB objects before the helper takes
    /// the BRIO. A queued stop alone does not complete the handoff.
    func stopAndWait() async {
        stop()
        await withCheckedContinuation { continuation in
            sessionQueue.async { continuation.resume() }
        }
    }

    private func retire(_ retired: AVCaptureSession) {
        sessionQueue.async {
            if retired.isRunning { retired.stopRunning() }
            retired.beginConfiguration()
            for output in retired.outputs {
                (output as? AVCaptureVideoDataOutput)?.setSampleBufferDelegate(nil, queue: nil)
                retired.removeOutput(output)
            }
            for input in retired.inputs { retired.removeInput(input) }
            retired.commitConfiguration()
        }
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

    /// Configuration, start, stop and teardown all run on sessionQueue.
    private nonisolated static func configureAndStart(
        _ session: AVCaptureSession, device: AVCaptureDevice,
        publisher: FramePublisher, queue: DispatchQueue
    ) -> String? {
        session.beginConfiguration()
        session.sessionPreset = .high
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(publisher, queue: queue)
        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input), session.canAddOutput(output) else {
                session.commitConfiguration()
                return "Could not connect to the selected camera."
            }
            session.addInput(input)
            session.addOutput(output)
            // Vision uses downscaled pixels; the native source retains detail
            // for glare analysis. macOS respects the explicit activeFormat.
            if let best = device.formats.max(by: { lhs, rhs in
                let l = CMVideoFormatDescriptionGetDimensions(lhs.formatDescription)
                let r = CMVideoFormatDescriptionGetDimensions(rhs.formatDescription)
                return Int(l.width) * Int(l.height) < Int(r.width) * Int(r.height)
            }) {
                try device.lockForConfiguration()
                device.activeFormat = best
                device.unlockForConfiguration()
            }
        } catch {
            session.commitConfiguration()
            return "Could not start the selected camera: " + error.localizedDescription
        }
        session.commitConfiguration()
        session.startRunning()
        return session.isRunning ? nil : "The selected camera could not start. Try again."
    }

    fileprivate func publish(frame: CameraFrame, generation: UInt64) {
        // A callback queued before stop must never become a new scan's proof.
        guard isRunning, self.generation == generation else { return }
        currentFrame = frame
    }

    /// Renders the detected face at native resolution for glare analysis.
    /// Background outside the face must not count as facial reflections.
    /// DeviceBezelDetector independently examines the full camera frame.
    nonisolated static func renderCrop(from frame: CameraFrame, imageRect: CGRect, maxEdge: CGFloat = 448) -> CGImage? {
        let workingWidth = CGFloat(frame.image.width)
        let workingHeight = CGFloat(frame.image.height)
        guard workingWidth > 0, workingHeight > 0 else { return nil }
        let scaleX = frame.sourceSize.width / workingWidth
        let scaleY = frame.sourceSize.height / workingHeight

        // Flip from `imageRect`'s top-left/y-down space to Core Image's bottom-left/y-up (reverse of FaceDetector.convertToImageSpace).
        let nativeX = imageRect.origin.x * scaleX
        let nativeWidth = imageRect.width * scaleX
        let nativeHeight = imageRect.height * scaleY
        let nativeY = frame.sourceSize.height - (imageRect.origin.y + imageRect.height) * scaleY
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
    nonisolated private final class FramePublisher: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
        private weak var owner: CameraManager?
        private let generation: UInt64

        init(owner: CameraManager, generation: UInt64) {
            self.owner = owner
            self.generation = generation
            super.init()
        }
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
            let capturedAt = ContinuousClock.now
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
                capturedAt: capturedAt,
                image: cgImage,
                source: sourceImage,
                sourceSize: sourceExtent.size
            )

            Task { @MainActor [weak owner, generation] in
                owner?.publish(frame: frame, generation: generation)
            }
        }
    }
}
