import AppKit
import SwiftUI

/// A non-drawing view laid out with the visible panel, before its shadow.
/// Its bounds follow SwiftUI's size and position animations, so transparent
/// margins and rounded corners never become an interactive rectangle.
struct NotchInteractionRegion: NSViewRepresentable, Animatable {
    var shape: NotchShape
    var onHover: (Bool) -> Void

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { shape.animatableData }
        set { shape.animatableData = newValue }
    }

    func makeNSView(context: Context) -> RegionView { RegionView() }

    func updateNSView(_ view: RegionView, context: Context) {
        view.shape = shape
        view.onHover = onHover
    }

    final class RegionView: NSView {
        var shape = NotchShape(topRadius: 0, bottomRadius: 0)
        var onHover: ((Bool) -> Void)?
        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            (window as? NotchWindow)?.interactionRegion = self
        }

        func contains(screenPoint: NSPoint) -> Bool {
            guard let window else { return false }
            let point = convert(window.convertPoint(fromScreen: screenPoint), from: nil)
            return shape.path(in: bounds).contains(point)
        }
    }
}
