//
//  CameraPreviewView.swift
//  glance
//


import SwiftUI
import AVFoundation
import AppKit

struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession
    var faces: [DetectedFace] = []

    func makeNSView(context: Context) -> PreviewHostView {
        PreviewHostView(session: session)
    }

    func updateNSView(_ nsView: PreviewHostView, context: Context) {
        nsView.updateFaceBoxes(faces)
    }
}

final class PreviewHostView: NSView {
    private let previewLayer: AVCaptureVideoPreviewLayer
    private var boxLayers: [CAShapeLayer] = []

    init(session: AVCaptureSession) {
        previewLayer = AVCaptureVideoPreviewLayer(session: session)
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        // .resizeAspectFill crops to fill the view — without it, the sensor's aspect ratio leaves gaps inside a circular mask.
        previewLayer.videoGravity = .resizeAspectFill
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // bounds+position, not .frame — Core Animation mis-reports .frame once a non-identity transform is applied.
        previewLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        previewLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        // Mirror horizontally at the layer level — the capture connection's isVideoMirrored had no effect here.
        previewLayer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
        CATransaction.commit()
    }

    func updateFaceBoxes(_ faces: [DetectedFace]) {
        boxLayers.forEach { $0.removeFromSuperlayer() }
        boxLayers = faces.map { face in
            // Vision's `normalizedBoundingBox` uses a bottom-left origin (y up), while
            // `layerRectConverted(fromMetadataOutputRect:)` expects AVFoundation metadata space (top-left origin, y down).
            let box = face.normalizedBoundingBox
            let metadataRect = CGRect(
                x: box.origin.x,
                y: 1 - box.origin.y - box.height,
                width: box.width,
                height: box.height
            )
            let rect = previewLayer.layerRectConverted(fromMetadataOutputRect: metadataRect)
            let shape = CAShapeLayer()
            shape.path = CGPath(rect: rect, transform: nil)
            shape.strokeColor = NSColor.systemGreen.cgColor
            shape.fillColor = NSColor.clear.cgColor
            shape.lineWidth = 2
            previewLayer.addSublayer(shape)
            return shape
        }
    }
}
