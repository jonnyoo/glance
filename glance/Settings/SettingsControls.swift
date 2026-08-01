//
//  SettingsControls.swift
//  glance
//
//  Reusable pieces for the Settings window: a pill-shaped setting row (the
//  Figma design's repeated row chrome), a custom toggle matching its exact
//  track/knob sizing (SwiftUI's stock `Toggle` can't match that), a slider
//  row, an action-button row, the background blur, and the NSWindow chrome
//  configurator (non-resizable, greyed-out miniaturize/zoom).
//

import SwiftUI
import AppKit


/// One settings row: label (+ optional subtitle) on the leading edge,
/// arbitrary trailing control. Matches the pill-shaped rows in the Figma
/// design (430x50, radius 17, translucent fill + hairline border).
struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SettingsMetrics.rowFont)
                    .foregroundStyle(SettingsMetrics.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsMetrics.textSecondary)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
        .frame(height: SettingsMetrics.rowHeight)
        .background(SettingsMetrics.rowColor)
        .overlay(
            RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius)
                .strokeBorder(SettingsMetrics.rowBorder, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius))
    }
}

/// The system switch, so it picks up AppKit's own rendering (Liquid Glass
/// on macOS 26) rather than a hand-drawn approximation.
///
/// This only renders correctly because the window is `.titled` and can
/// therefore become key — see `WindowConfiguringView.configure`. In a
/// never-key window AppKit draws this desaturated and ignores `.tint`
/// entirely, which is what previously forced a hand-drawn replacement.
struct GlanceToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .tint(GlanceTheme.accent)
    }
}

/// A row combining a title/subtitle with a slider and its live numeric
/// value — used for the raw threshold controls on the Recognition page.
struct SettingsSlider: View {
    let title: String
    var subtitle: String? = nil
    let value: Binding<Float>
    let range: ClosedRange<Float>
    var format: (Float) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(SettingsMetrics.rowFont)
                        .foregroundStyle(SettingsMetrics.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(SettingsMetrics.textSecondary)
                    }
                }
                Spacer()
                Text(format(value.wrappedValue))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(SettingsMetrics.textSecondary)
            }
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Float($0) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound)
            )
            .tint(GlanceTheme.accent)
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
        .padding(.vertical, 10)
        .background(SettingsMetrics.rowColor)
        .overlay(
            RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius)
                .strokeBorder(SettingsMetrics.rowBorder, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius))
    }
}

/// A row pairing a title/subtitle with an action button — used for "Redo
/// Face Enrollment", "Change Password", etc.
struct SettingsActionRow: View {
    let title: String
    var subtitle: String? = nil
    let buttonTitle: String
    var isDestructive: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            Button(action: action) {
                Text(buttonTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(isDestructive ? Color.red.opacity(0.85) : GlanceTheme.accent)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.4)
        }
    }
}

/// Traces only the *leading* edge of the content panel — the top-leading
/// curve, the straight left edge, and the bottom-leading curve — so the
/// sidebar/content seam stroke wraps around the panel's rounded corners
/// instead of cutting across them as a straight vertical line. The trailing
/// edge is deliberately not part of the path: it sits flush against the
/// window edge, where the system already draws its own treatment.
///
/// Uses tangent-based arcs rather than angle-based ones to sidestep the
/// usual confusion about which direction `clockwise:` means in SwiftUI's
/// y-down coordinate space.
struct ContentPanelLeadingEdge: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + topRadius, y: rect.minY))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY),
            tangent2End: CGPoint(x: rect.minX, y: rect.maxY),
            radius: topRadius
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.maxY),
            radius: bottomRadius
        )
        return path
    }
}

/// A blur that gets progressively stronger toward the top edge, instead of
/// a flat, uniformly-blurred rectangle. SwiftUI has no native "variable
/// blur radius" — this fakes it with the standard trick of stacking several
/// material layers, each masked by a linear gradient that fades out at a
/// different point. Near the top, all layers overlap (strongest, most
/// opaque blur); further down, fewer layers remain, so it thins out and
/// blends into the plain content underneath instead of ending in a hard
/// edge.
struct ProgressiveBlurView: View {
    var body: some View {
        ZStack {
            layer(.ultraThinMaterial, fadeEnd: 0.35)
            layer(.ultraThinMaterial, fadeEnd: 0.65)
            layer(.thinMaterial, fadeEnd: 1.0)
        }
        .allowsHitTesting(false)
    }

    private func layer(_ material: Material, fadeEnd: CGFloat) -> some View {
        Rectangle()
            .fill(material)
            .mask(
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .clear, location: fadeEnd),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
    }
}

/// Section caption used above a group of rows on a settings page (distinct
/// from the sidebar's own section headers).
struct SettingsCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(SettingsMetrics.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Wraps an `NSVisualEffectView` for the window's background blur.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

/// Configures the hosting `NSWindow`'s chrome once it's available: fully
/// borderless (see `WindowConfiguringView` for why), fixed-size, and
/// background-draggable since there's no title bar to grab.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowConfiguringView {
        WindowConfiguringView()
    }

    func updateNSView(_ nsView: WindowConfiguringView, context: Context) {}
}

/// Strips the window down to `.borderless` so the SwiftUI content *is* the
/// window, with no competing system chrome at all.
///
/// A `.titled` window (even fully transparent) kept showing a mismatched,
/// smaller-radius system corner/edge treatment poking out behind the custom
/// 40pt-radius panel — and real traffic-light buttons can't be repositioned
/// via any public AppKit API, which the design calls for (more inset from
/// the corner). Going borderless removes both problems at once: no system
/// corner competing with ours, and the traffic lights are now
/// `TrafficLightsView` — hand-drawn, positioned wherever the design wants.
/// Only the red one is wired to actually close the window; the other two
/// are permanently inert, matching the earlier greyed-out requirement.
///
/// Note: no `setFrame`/`setContentSize` on every layout pass — that fought
/// SwiftUI's own resize-to-fit-content pass in a mutual invalidation loop
/// and crashed with an AppKit constraint-pass exception in an earlier
/// version. Size is set exactly once, here, since nothing else can resize
/// a non-resizable, borderless window afterward.
final class WindowConfiguringView: NSView {
    private var hasConfigured = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !hasConfigured else { return }
        hasConfigured = true

        // Deferred by one runloop turn on purpose. This method is called
        // from inside `-[NSView _setWindow:]`, part-way through a SwiftUI
        // render pass — mutating the window there (in particular swapping
        // its class for key-window support) corrupts an AppKit-internal
        // unfair lock and hard-crashes in `_NSSetBoolValueAndNotify`.
        // Waiting until the attachment has finished avoids that entirely.
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            Self.configure(window)
        }
    }

    private static func configure(_ window: NSWindow) {
        // `.titled` is essential and non-obvious: AppKit only lets a window
        // become *key* if it has a title bar or resize bar, and a window
        // that is never key draws every control inside it in the inactive
        // appearance — desaturated, foggy, tint ignored. That's what made
        // the native toggles/sliders render dark monochrome under the
        // previous `.borderless` mask. The title bar is then made fully
        // invisible below, so this costs nothing visually.
        //
        // (Trying to keep `.borderless` and override `canBecomeKey` via a
        // runtime subclass does not work: SwiftUI already has KVO observers
        // on this window, so KVO has itself isa-swizzled it, and swapping
        // the class out from under that crashes in `_NSSetBoolValueAndNotify`.)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        // We draw our own traffic lights (TrafficLightsView) so the design
        // can place them where it wants; the real ones would otherwise show
        // through at the system's fixed position.
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true

        // No manual corner-radius override here — deliberately. AppKit
        // already rounds a `.titled` window's corners on its own, and that
        // native radius is exactly what should show: it's what makes this
        // window's corners match System Settings / Control Center rather
        // than looking like a custom shape pretending to be native. See
        // SettingsMetrics.outerCornerRadius for how that native radius was
        // measured and reused for our own SwiftUI-side clipping, so the two
        // align instead of one fighting the other (which is what caused the
        // original mismatched-corner artifact, back when our own clip used
        // an arbitrary, much larger radius than the system's).

        let target = SettingsMetrics.windowSize
        var frame = window.frame
        frame.origin.y += frame.height - target.height // keep the top edge fixed
        frame.size = NSSize(width: target.width, height: target.height)
        window.setFrame(frame, display: true)

        // Belt-and-suspenders non-resizability: `.resizable` is already
        // absent from styleMask above (AppKit's authoritative capability
        // flag — without it there's no resize cursor and no edge/corner
        // drag-to-resize at all), and pinning min == max additionally
        // forecloses any other path to a size change (e.g. window-manager
        // tiling/snap gestures) from ever having anywhere to go.
        window.minSize = target
        window.maxSize = target

        NSApp.activate()
        window.makeKeyAndOrderFront(nil)

        // Captured directly rather than relying on `NSApp.keyWindow` at
        // click time — simpler than re-deriving it later.
        SettingsWindowReference.window = window
    }
}

/// See `WindowConfiguringView` — holds the one settings window so
/// `TrafficLightsView`'s close button doesn't have to guess at
/// `NSApp.keyWindow`.
enum SettingsWindowReference {
    static weak var window: NSWindow?
}


/// Hand-drawn traffic-light replicas. Necessary once the window went
/// borderless (see `WindowConfiguringView`) — there's no real title bar left
/// to host real ones, and repositioning real traffic lights isn't possible
/// via any public API anyway. Only red is functional.
///
/// Real `Button`s rather than a bare `.onTapGesture` — buttons get correct
/// AppKit click handling (mouseDown/mouseUp through the normal responder
/// chain) and show up as real, inspectable controls in the accessibility
/// tree, unlike a tap gesture on a plain shape.
struct TrafficLightsView: View {
    private let red = Color(red: 1.0, green: 0.373, blue: 0.341)
    private let inertGray = Color.white.opacity(0.16)

    var body: some View {
        HStack(spacing: 8) {
            Button {
                SettingsWindowReference.window?.close()
            } label: {
                Circle().fill(red).frame(width: 12, height: 12)
            }
            .buttonStyle(.plain)

            Circle().fill(inertGray).frame(width: 12, height: 12)
            Circle().fill(inertGray).frame(width: 12, height: 12)
        }
    }
}
