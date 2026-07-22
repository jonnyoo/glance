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
        // .resizeAspectFill crops to completely fill the view instead of
        // letterboxing — without it, the sensor's rectangular aspect ratio
        // leaves visible gaps inside a circular mask.
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
        // Geometry is set via bounds+position (not .frame) because a
        // non-identity transform is applied below, and Core Animation
        // mis-reports .frame once a layer is transformed.
        previewLayer.bounds = CGRect(origin: .zero, size: bounds.size)
        previewLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        // Horizontal flip so the preview reads like a mirror (turn head
        // left -> moves left on screen). Done at the layer level rather
        // than via the capture connection's isVideoMirrored, which had no
        // effect on this hardware/preview combination.
        previewLayer.setAffineTransform(CGAffineTransform(scaleX: -1, y: 1))
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
