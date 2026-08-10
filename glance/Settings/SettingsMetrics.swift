//
//  SettingsMetrics.swift
//  glance
//
//  Design tokens for the Settings window, measured from the Figma design
//  (node 83:10). Mirrors the existing OnboardingMetrics.swift pattern — one
//  file to tune sizing/color in rather than scattered literals. Window size
//  is 660x710 (Figma's 700x755 scaled down slightly, per request), every
//  other value below is kept 1:1 with the design.
//

import SwiftUI

enum SettingsMetrics {
    static let windowSize = CGSize(width: 620, height: 650)
    /// There is deliberately no `outerCornerRadius` token any more. The
    /// window's outer corner is AppKit's own — macOS 26 rounds it to ~26pt
    /// with a *continuous* (squircle) curve, verified by capturing window
    /// alpha masks with `screencapture -o -l<windowID>` and comparing this
    /// window's traced corner against Finder's (identical, 0.00px RMSE).
    /// Hardcoding it here is what made the corners look wrong before: our
    /// own clip could only cut *inside* the system shape, so a stale
    /// constant silently won. See SettingsWindowView / WindowConfiguringView.
    ///
    /// Vertical strip at the top of the sidebar left empty for the window's
    /// real traffic lights, which AppKit draws over our content because the
    /// window is `.fullSizeContentView`.
    static let trafficLightBandHeight: CGFloat = 52
    static let contentCornerRadius: CGFloat = 19
    static let sidebarWidth: CGFloat = 190

    /// The content panel's fill — solid, not translucent, so it reads as an
    /// opaque card rather than picking up whatever's behind the window (that
    /// bleed-through via `VisualEffectView`'s materials was the "colored
    /// glow" the header used to show).
    static let contentBackgroundColor = adaptiveColor(
        dark: NSColor(red: 0x10 / 255, green: 0x10 / 255, blue: 0x10 / 255, alpha: 0.25),
        light: NSColor(white: 1, alpha: 0.25)
    )

    /// The sidebar's fill: the same per-appearance color as the content
    /// panel, but translucent, so the sidebar still reads as a distinct,
    /// lighter layer floating over `VisualEffectView`'s blur rather than a
    /// second flat card butted up against the first.
    ///
    /// Alpha dropped from 0.35 deliberately, not just for looks: at 0.35 this
    /// flat wash was strong enough to bury almost all of the real vibrancy
    /// coming through `VisualEffectView` underneath it, which is what made
    /// the sidebar read as a static gray panel instead of actual glass. A
    /// wallpaper-file-reading hack was tried and reverted (see git history)
    /// to fix that — the simpler, correct fix was just to stop hiding the
    /// genuine `.behindWindow` blur that was already there. Confirmed
    /// against a reference app (Alcove's own Settings window) known to have
    /// the desired look: placing a fully saturated, opaque backdrop directly
    /// behind its window barely moved its rendered color, meaning it isn't
    /// running a special sampling trick either — it's a real, honestly
    /// vibrant `NSVisualEffectView` through a heavily-desaturating material,
    /// same as this one.
    static let sidebarBackgroundColor = adaptiveColor(
        dark: NSColor(red: 0x37 / 255, green: 0x37 / 255, blue: 0x37 / 255, alpha: 0),
        light: NSColor(red: 0xFF / 255, green: 0xFF / 255, blue: 0xFF / 255, alpha: 0)
    )

    /// Gap between the content panel and every window edge — including the
    /// sidebar seam — now that the panel floats as its own card instead of
    /// sitting flush against the window frame.
    static let contentOuterSpacing: CGFloat = 8
    static let contentShadowColor = Color.black.opacity(0.2)
    static let contentShadowRadius: CGFloat = 8

    /// A hairline edge around the content panel — an actual grey in both
    /// appearances (unlike `rowBorder`/`selectedPillColor` elsewhere in this
    /// file, which fake "grey" via a translucent black or white tint). The
    /// panel already carries its own appearance-correct fill; the stroke
    /// just needs to read as a slightly darker (light mode) or slightly
    /// lighter (dark mode) edge against it, not introduce another tint of
    /// its own. Kept deliberately faint — `0.3` alpha over a hairline
    /// `0.5pt` width — so it defines the card's edge without competing with
    /// the shadow that already separates it from the sidebar.
    static let contentStrokeColor = adaptiveColor(
        dark: NSColor(white: 0.5, alpha: 0.3),
        light: NSColor(white: 0.5, alpha: 0.3)
    )

    static let selectedPillRadius: CGFloat = 11
    /// A touch of *lightness* over the sidebar reads as "selected" against
    /// the sidebar's dark translucent fill; over the light-mode fill (also
    /// translucent, but toward white) the same white tint would be nearly
    /// invisible, so light mode instead uses a touch of *darkness* — same
    /// role, opposite direction, chosen at a matching visual weight.
    static let selectedPillColor = adaptiveColor(
        dark: NSColor(white: 1, alpha: 0.06),
        light: NSColor(white: 1, alpha: 0.4)
    )

    static let sidebarItemHeight: CGFloat = 32
    static let sidebarSectionSpacing: CGFloat = 8
    static let sidebarItemFont = Font.system(size: 14, weight: .medium)
    static let sectionHeaderFont = Font.system(size: 11, weight: .semibold)
    static let contentTitleFont = Font.system(size: 18, weight: .medium)

    /// Dark-mode values are unchanged, hand-measured-from-Figma literals.
    /// Light-mode values aren't a separate guess: they're the exact resolved
    /// alpha AppKit's own `NSColor.labelColor` / `.secondaryLabelColor` use
    /// in light mode (`black @ 0.85` / `black @ 0.50` — checked directly via
    /// `NSAppearance.performAsCurrentDrawingAppearance`, not from docs),
    /// so light-mode text reads with exactly the contrast every other native
    /// light-mode app uses, while dark mode stays pixel-identical to before.
    static let textPrimary = adaptiveColor(
        dark: NSColor(red: 0xEE / 255, green: 0xEE / 255, blue: 0xEE / 255, alpha: 1),
        light: NSColor(white: 0, alpha: 0.85)
    )
    static let textSecondary = adaptiveColor(
        dark: NSColor(red: 0xBF / 255, green: 0xBF / 255, blue: 0xBF / 255, alpha: 1),
        light: NSColor(white: 0, alpha: 0.50)
    )

    static let rowHeight: CGFloat = 50
    static let rowRadius: CGFloat = 17
    /// Same "flip the tint direction for a light background" logic as
    /// `selectedPillColor` above: a white-tinted row reads as a raised card
    /// against the dark content panel; on the white light-mode panel the
    /// only way to still read as a distinct card is to go slightly *darker*
    /// than the page, not lighter.
    static let rowColor = adaptiveColor(
        dark: NSColor(white: 1, alpha: 0.05),
        light: NSColor(white: 0, alpha: 0.04)
    )
    static let rowBorder = adaptiveColor(
        dark: NSColor(white: 1, alpha: 0.07),
        light: NSColor(white: 0, alpha: 0.08)
    )
    static let rowFont = Font.system(size: 15, weight: .medium)
    static let rowSpacing: CGFloat = 12
    static let rowHorizontalInset: CGFloat = 19

    static let contentHorizontalPadding: CGFloat = 20
    static let headerHeight: CGFloat = 50

    /// No blur or scrim sits behind the header — settled on after trying,
    /// and rejecting, everything below. The header floats fully transparent
    /// over the scrolled content instead:
    ///
    ///  * a flat colour scrim (any colour, stacked or single) is a tint by
    ///    definition, which read as an "extra white band" over the panel;
    ///  * `NSVisualEffectView` blurs correctly but a macOS material is blur
    ///    *plus* a baked-in tint, with no API to take one without the other,
    ///    so it hit the same "extra white band" problem;
    ///  * `CALayer.backgroundFilters` + `CIGaussianBlur` is tint-free but
    ///    renders nothing inside SwiftUI's hosting view, even with the
    ///    required `layerUsesCoreImageFilters` opt-in;
    ///  * a Metal `layerEffect` shader cannot rasterize AppKit-backed views,
    ///    and this window's content is entirely native controls (Toggle,
    ///    Slider, Picker, SecureField, the camera preview) — they render as
    ///    "unsupported" placeholders, and `ScrollView` itself blanks out;
    ///  * a private-API `CABackdropLayer` + `CAFilter` `variableBlur` did
    ///    render a real, tint-free, progressive blur — the one approach that
    ///    actually worked — but wasn't wanted after seeing it in person.
    ///
    /// Don't re-attempt any of these without an explicit ask.
    /// system appearance rather than being fixed at whatever was true when
    /// this enum was evaluated. Every fill/text/row token in this file now
    /// goes through this — `GlanceTheme`'s accent/status colors are the only
    /// ones left as plain literals, since those are fixed brand/semantic
    /// colors (blue accent, red/green status dots) that are legible against
    /// both a dark and a light content panel unchanged, not something that
    /// should shift with appearance.
    private static func adaptiveColor(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}
