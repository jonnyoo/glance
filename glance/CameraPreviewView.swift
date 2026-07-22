//
//  CameraPreviewView.swift
//  glance
//
//  Milestone A/B display: shows the live camera feed and draws a green box
//  around each face Vision finds, updated every frame.
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
        previewLayer.videoGravity = .resizeAspect
        layer?.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }

    func updateFaceBoxes(_ faces: [DetectedFace]) {
        boxLayers.forEach { $0.removeFromSuperlayer() }
        boxLayers = faces.map { face in
            let rect = previewLayer.layerRectConverted(fromMetadataOutputRect: face.normalizedBoundingBox)
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
