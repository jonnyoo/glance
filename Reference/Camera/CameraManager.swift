//
//  CameraManager.swift
//  FaceUnlock
//

import AVFoundation
import Observation

@Observable
final class CameraManager {
    enum AuthorizationStatus {
        case notDetermined
        case denied
        case authorized
    }

    let session = AVCaptureSession()
    var authorizationStatus: AuthorizationStatus = .notDetermined
    var isRunning = false

    private let sessionQueue = DispatchQueue(label: "com.faceunlock.camera.session")
    private let videoOutputQueue = DispatchQueue(label: "com.faceunlock.camera.video-output")
    private let videoOutput = AVCaptureVideoDataOutput()
    private let frameReceiver = FrameReceiver()
    private var didConfigure = false

    private let bufferLock = NSLock()
    private var _latestPixelBuffer: CVPixelBuffer?

    init() {
        frameReceiver.owner = self
        refreshAuthorizationStatus()
    }

    func currentFrame() -> CVPixelBuffer? {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return _latestPixelBuffer
    }

    fileprivate func updateLatestBuffer(_ buffer: CVPixelBuffer) {
        bufferLock.lock()
        _latestPixelBuffer = buffer
        bufferLock.unlock()
    }

    func refreshAuthorizationStatus() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorizationStatus = .authorized
        case .denied, .restricted:
            authorizationStatus = .denied
        case .notDetermined:
            authorizationStatus = .notDetermined
        @unknown default:
            authorizationStatus = .denied
        }
    }

    func requestAccessAndStart() async {
        let granted = await AVCaptureDevice.requestAccess(for: .video)
        authorizationStatus = granted ? .authorized : .denied
        if granted {
            await start()
        }
    }

    func start() async {
        guard authorizationStatus == .authorized else { return }
        await withCheckedContinuation { continuation in
            sessionQueue.async { [weak self] in
                guard let self else {
                    continuation.resume()
                    return
                }
                self.configureSessionIfNeeded()
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                let running = self.session.isRunning
                DispatchQueue.main.async {
                    self.isRunning = running
                    continuation.resume()
                }
            }
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            // Drop the last captured frame so a subsequent restart can't
            // return a stale buffer from the previous session while waiting
            // for fresh frames to arrive.
            self.bufferLock.lock()
            self._latestPixelBuffer = nil
            self.bufferLock.unlock()
            DispatchQueue.main.async {
                self.isRunning = false
            }
        }
    }

    private func configureSessionIfNeeded() {
        guard !didConfigure else { return }
        session.beginConfiguration()
        session.sessionPreset = .high

        if let device = AVCaptureDevice.default(for: .video),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
        }

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA)
        ]
        videoOutput.setSampleBufferDelegate(frameReceiver, queue: videoOutputQueue)
        if session.canAddOutput(videoOutput) {
            session.addOutput(videoOutput)
        }

        session.commitConfiguration()
        didConfigure = true
    }
}

private final class FrameReceiver: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    weak var owner: CameraManager?

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        owner?.updateLatestBuffer(buffer)
    }
}
