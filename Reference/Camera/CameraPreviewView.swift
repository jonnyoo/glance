//
//  CameraPreviewView.swift
//  FaceUnlock
//

import SwiftUI
import AVFoundation

struct CameraPreviewView: NSViewRepresentable {
    let session: AVCaptureSession

    func makeNSView(context: Context) -> PreviewNSView {
        let view = PreviewNSView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateNSView(_ nsView: PreviewNSView, context: Context) {
        if nsView.previewLayer.session !== session {
            nsView.previewLayer.session = session
        }
    }

    final class PreviewNSView: NSView {
        let previewLayer = AVCaptureVideoPreviewLayer()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layerContentsRedrawPolicy = .duringViewResize
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func makeBackingLayer() -> CALayer {
            return previewLayer
        }
    }
}
