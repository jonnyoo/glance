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
import CoreImage


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

/// A scrim behind the header that fades out toward the bottom, instead of
/// ending in a hard edge where scrolled rows disappear underneath it.
///
/// This used to be a stack of `Material` layers (`.ultraThinMaterial` /
/// `.thinMaterial`) rather than a flat color — but a `behindWindow`-blending
/// material samples whatever is actually behind the window (see
/// `VisualEffectView`), so the header picked up a "colored glow" from
/// whatever was on the desktop behind it. Swapping the material for
/// `SettingsMetrics.contentBackgroundColor` removes that bleed-through
/// entirely: the header now reads as the same solid panel color, just
/// fading into the content below it, with nothing sampled from outside the
/// window. The stacked-layers-with-staggered-fades trick is kept as-is
/// (still no native "variable fade" in SwiftUI) since it's still what gives
/// the fade its non-linear, front-loaded shape rather than a flat ramp.
struct HeaderScrimView: View {
    var body: some View {
        ZStack {
            layer(fadeEnd: 0.35)
            layer(fadeEnd: 0.65)
            layer(fadeEnd: 1.0)
        }
        .allowsHitTesting(false)
    }

    private func layer(fadeEnd: CGFloat) -> some View {
        Rectangle()
            .fill(SettingsMetrics.contentBackgroundColor)
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
///
/// Also boosts the saturation of whatever's behind the window before the
/// blur reaches the sidebar — `.hudWindow` is a deliberately near-monochrome
/// material (it's built for on-screen HUDs, not for showing off the
/// backdrop), so raw `.behindWindow` sampling here comes through almost
/// flat gray. See `saturationFilter` for how that's measured and corrected.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    /// `CALayer.filters` (not `.backgroundFilters`, and not
    /// `.compositingFilter`) is the one that actually reaches this view's
    /// rendered content — confirmed empirically, not from documentation:
    /// with a saturated gradient placed behind a plain `.hudWindow` blur
    /// window and `screencapture -o` sampling the composited pixels,
    /// `.filters` and `.compositingFilter` both roughly doubled the
    /// backdrop's average HSV saturation at `inputSaturation: 1.6`;
    /// `.backgroundFilters` moved it by less than a third as much. `.filters`
    /// was picked over `.compositingFilter` as the more conventional/
    /// supported route for "post-process this layer's own contents".
    ///
    /// `2.0` was chosen the same way: saturation scaled roughly linearly
    /// with `inputSaturation` from 1.0 (flat gray, ~0.023 avg saturation) up
    /// through 8.0 (an overtly warm/orange tint, ~0.166) with no sign of an
    /// early ceiling, so there's real headroom either direction. `2.0` reads
    /// as a visible-but-subtle warm lift rather than a color cast — a
    /// "slightly saturated" request, not a "vivid" one.
    private static let saturationFilter: CIFilter = {
        let filter = CIFilter(name: "CIColorControls")!
        filter.setValue(1.05, forKey: "inputSaturation")
        return filter
    }()

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        // `.followsWindowActiveState`, *not* `.active`. This is the whole
        // reason a native window stops being see-through the moment you
        // switch apps while ours stayed translucent forever: `.active`
        // pins the material on permanently, so the blur keeps sampling the
        // desktop even when the window is neither key nor main. Following
        // the window's state is what AppKit's own sidebars/toolbars do —
        // vibrancy while frontmost, a flat opaque background behind.
        view.state = .followsWindowActiveState
        view.wantsLayer = true
        view.layer?.filters = [Self.saturationFilter]
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

/// Makes the hosting window an ordinary macOS window that simply doesn't
/// draw a title bar — rather than a custom-shaped window imitating one.
///
/// This is a deliberate reversal of an earlier approach that faked the
/// chrome: a borderless/transparent window, hand-drawn traffic lights, and
/// a SwiftUI `clipShape` standing in for the window's corners. Every one of
/// those pieces had to be maintained against the OS instead of by it, and
/// each drifted:
///
///  * the hand-picked corner radius couldn't track macOS 26's much rounder
///    (and continuous-curve) window corners, and being a clip it could only
///    ever cut *inside* the real shape, so it silently won;
///  * hand-drawn traffic lights don't grey out with window state, don't
///    respond to the hover glyphs, and aren't in the accessibility tree;
///  * a permanently-`.active` background material never dropped its
///    vibrancy when the app lost focus, so the window stayed see-through
///    while every real window around it had gone opaque.
///
/// Keeping the real window and only suppressing the titlebar's *drawing*
/// gets all of that back from AppKit for free. See the individual comments
/// in `configure` for what each line buys and why removing it regresses.
///
/// Note: no `setFrame`/`setContentSize` on every layout pass — that fought
/// SwiftUI's own resize-to-fit-content pass in a mutual invalidation loop
/// and crashed with an AppKit constraint-pass exception in an earlier
/// version. Size is set exactly once, here, since nothing else can resize
/// a non-resizable window afterward.
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
        // `.fullSizeContentView` + transparent titlebar + hidden title is
        // the *supported* way to get "no title bar": the window keeps all of
        // its real titlebar machinery — real traffic lights, native frame,
        // native corner mask, native active/inactive appearance — it just
        // doesn't draw a chrome band across the top, and our content extends
        // up underneath it.
        //
        // `.titled` is also load-bearing beyond appearance: AppKit only lets
        // a window become *key* if it has a title bar or resize bar, and a
        // window that is never key draws every control inside it in the
        // inactive appearance — desaturated, foggy, tint ignored. That's
        // what made the native toggles/sliders render dark monochrome back
        // when this was a `.borderless` window. (Keeping `.borderless` and
        // overriding `canBecomeKey` via a runtime subclass does not work
        // either: SwiftUI already has KVO observers on this window, so KVO
        // has itself isa-swizzled it, and swapping the class out from under
        // that crashes in `_NSSetBoolValueAndNotify`.)
        //
        // `.miniaturizable` is present so the yellow button genuinely works.
        // `.resizable` is deliberately absent, which is also what disables
        // the green button (`isZoomable` becomes false) — natively, rather
        // than by drawing a dead control that only looks disabled.
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        // An empty, item-less `NSToolbar` — and this is the single thing
        // that buys the macOS 26 corner radius. Measured, not folklore: with
        // window alpha masks captured via `screencapture -o -l<windowID>`
        // and traced, an otherwise identical window rounds to 17.5pt with no
        // toolbar, 23pt with `.unifiedCompact`, and exactly Finder's radius
        // (0.00px RMSE over the whole corner curve) with `.unified`. Tahoe
        // ties the corner radius to the height of the titlebar band, so the
        // taller unified band is what makes the corner rounder — there is no
        // corner-radius API to set, and hardcoding a radius is precisely the
        // thing that made it wrong before.
        //
        // Nothing of the toolbar is visible: it has no items, no delegate,
        // and the titlebar above is transparent with the content drawn
        // underneath it, so this only reserves the band the traffic lights
        // sit in (SettingsMetrics.trafficLightBandHeight keeps our sidebar
        // clear of it).
        let toolbar = NSToolbar(identifier: "GlanceSettingsToolbar")
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        window.isMovableByWindowBackground = true
        window.hasShadow = true

        // Deliberately NOT `isOpaque = false` / `backgroundColor = .clear`.
        // That pairing is what cost this window its native corners: it makes
        // AppKit stop drawing (and stop masking to) the window's own rounded
        // frame, leaving whatever the SwiftUI content clipped itself to as
        // the only visible shape — which is why the corners were stuck at a
        // hand-picked radius that no longer matches macOS 26's much rounder
        // native one, and why nothing here could ever track a future OS
        // change to it. Left at the AppKit defaults, the system mask applies
        // and the corner is the real thing, exactly like Finder's.
        //
        // Translucency does not need a clear background colour: the
        // `NSVisualEffectView` behind the content blends with what's behind
        // the window on its own (see VisualEffectView), and being a real
        // window background is what lets it go opaque when the app is not
        // frontmost, the way every native window does.

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
    }
}

// (No `SettingsWindowReference` any more: it existed only so the hand-drawn
// close button had a window to call `close()` on. The real traffic lights
// are wired up by AppKit.)
