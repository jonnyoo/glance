// AppKit/SwiftUI integration check; opens a small temporary window without
// touching the camera, credentials, or Accessibility permissions.
// Compile with NotchWindow.swift, NotchInteractionRegion.swift,
// NotchShape.swift, and NotchPanelStyle.swift using Swift 6.2+.
import AppKit
import SwiftUI

// These constants are only referenced by NotchShape's #Preview declarations.
enum NotchGeometry {
    static let pillClosedSize = CGSize(width: 140, height: 32)
    static let pillOpenCornerRadius: CGFloat = 32
}

@MainActor @Observable private final class PanelState {
    var width: CGFloat = 180
    var height: CGFloat = 80
    var offset: CGFloat = 20
}

private struct TestPanel: View {
    let state: PanelState
    var body: some View {
        Color.black
            .frame(width: state.width, height: state.height)
            .clipShape(NotchShape(topRadius: 30, bottomRadius: 30, style: .pill))
            .background {
                NotchInteractionRegion(shape: NotchShape(topRadius: 30, bottomRadius: 30, style: .pill)) { _ in }
            }
            .offset(y: state.offset)
            .frame(width: 434, height: 383, alignment: .top)
    }
}

@main private struct InputCheck {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let state = PanelState()
        let underneath = NSWindow(
            contentRect: NSRect(x: 80, y: 80, width: 434, height: 383),
            styleMask: .borderless, backing: .buffered, defer: false
        )
        underneath.isReleasedWhenClosed = false
        underneath.backgroundColor = .white
        underneath.orderFrontRegardless()
        defer { underneath.orderOut(nil) }
        let panel = NotchWindow(contentRect: NSRect(x: 80, y: 80, width: 434, height: 383))
        panel.contentView = NSHostingView(rootView: TestPanel(state: state))
        panel.orderFrontRegardless()
        defer { panel.stopPointerTracking(); panel.orderOut(nil) }
        pump(0.2)
        guard let region = panel.interactionRegion else { fatalError("No interaction region") }
        func screen(_ point: CGPoint) -> CGPoint { panel.convertPoint(toScreen: region.convert(point, to: nil)) }
        let inside = screen(CGPoint(x: 90, y: 40))
        let corner = screen(CGPoint(x: 1, y: 1))
        let outside = screen(CGPoint(x: -20, y: 40))
        check(region.contains(screenPoint: inside), "shape center")
        check(!region.contains(screenPoint: corner), "rounded corner excluded")
        check(!region.contains(screenPoint: outside), "transparent margin excluded")
        panel.interaction = .hover
        panel.updatePointer(at: inside)
        check(panel.ignoresMouseEvents, "hover stays click-through")
        pump(0.03)
        check(NSWindow.windowNumber(at: inside, belowWindowWithWindowNumber: 0) == underneath.windowNumber,
              "WindowServer targets underlying window through hover overlay")
        panel.interaction = .controls
        panel.updatePointer(at: inside)
        check(!panel.ignoresMouseEvents, "controls receive clicks inside")
        pump(0.03)
        check(NSWindow.windowNumber(at: inside, belowWindowWithWindowNumber: 0) == panel.windowNumber,
              "WindowServer targets onboarding inside the shape")
        panel.updatePointer(at: corner)
        check(panel.ignoresMouseEvents, "rounded corner passes clicks through")
        panel.updatePointer(at: outside)
        check(panel.ignoresMouseEvents, "margin passes clicks through")
        pump(0.03)
        check(NSWindow.windowNumber(at: outside, belowWindowWithWindowNumber: 0) == underneath.windowNumber,
              "WindowServer targets underlying window through transparent margin")
        func mouse(_ type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: panel.convertPoint(fromScreen: point),
                               modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: panel.windowNumber, context: nil,
                               eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
        }
        panel.updatePointer(at: inside)
        panel.sendEvent(mouse(.leftMouseDown, at: inside))
        panel.updatePointer(at: outside)
        check(!panel.ignoresMouseEvents, "drag retains capture outside the popup")
        panel.sendEvent(mouse(.leftMouseUp, at: outside))
        panel.updatePointer(at: outside)
        check(panel.ignoresMouseEvents, "release restores outside click-through")
        panel.sendEvent(mouse(.leftMouseDown, at: inside))
        panel.interaction = .hover
        panel.interaction = .controls
        panel.updatePointer(at: outside)
        check(panel.ignoresMouseEvents, "mode change clears stale drag capture")
        check(panel.canBecomeKey, "keyboard eligibility survives pointer exit")
        panel.interaction = .none
        panel.updatePointer(at: inside)
        check(panel.ignoresMouseEvents, "decorative state passes clicks through")

        withAnimation(.linear(duration: 0.5)) {
            state.width = 320
            state.height = 160
            state.offset = 80
        }
        var widths: [CGFloat] = []
        var positions: [CGFloat] = []
        for _ in 0..<35 {
            pump(0.02)
            widths.append(region.bounds.width)
            positions.append(region.convert(.zero, to: nil).y)
        }
        check(widths.contains { $0 > 185 && $0 < 315 }, "region follows intermediate resize frames")
        check(positions.max()! - positions.min()! > 30, "region follows slide")
        check(abs(region.bounds.width - 320) < 1, "region reaches final width")
        panel.orderOut(nil)
        panel.interaction = .controls
        panel.updatePointer(at: inside)
        check(panel.ignoresMouseEvents, "hidden window ignores clicks")
        print("PASS: all overlay input checks")
    }

    @MainActor private static func pump(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }
    private static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError("FAIL: \(message)") }
        print("PASS: \(message)")
        fflush(stdout)
    }
}
