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
    /// Opaque fill used only by the panel's shadow-casting underlay — same
    /// RGB as `contentBackgroundColor`, full alpha — so the drop shadow
    /// follows the card outline instead of every SettingsRow's silhouette.
    static let contentShadowFill = adaptiveColor(
        dark: NSColor(red: 0x10 / 255, green: 0x10 / 255, blue: 0x10 / 255, alpha: 0.2),
        light: NSColor(white: 1, alpha: 0.2)
    )

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
    static let sidebarItemFont = Font.system(size: 14, weight: .regular)
    static let sectionHeaderFont = Font.system(size: 14, weight: .medium)
    static let contentTitleFont = Font.system(size: 16, weight: .medium)

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
    static let textTertiary = adaptiveColor(
        dark: NSColor(red: 0x99 / 255, green: 0x99 / 255, blue: 0x99 / 255, alpha: 1),
        light: NSColor(white: 0, alpha: 0.4)
    )

    static let rowHeight: CGFloat = 44
    static let rowRadius: CGFloat = 16
    /// Same "flip the tint direction for a light background" logic as
    /// `selectedPillColor` above: a white-tinted row reads as a raised card
    /// against the dark content panel; on the white light-mode panel the
    /// only way to still read as a distinct card is to go slightly *darker*
    /// than the page, not lighter.
    static let rowColor = adaptiveColor(
        dark: NSColor(white: 1, alpha: 0.08),
        light: NSColor(white: 1, alpha: 0.75)
    )
    static let rowBorder = adaptiveColor(
        dark: NSColor(white: 0.8, alpha: 0.12),
        light: NSColor(white: 0, alpha: 0.15)
    )
    static let rowBorderWidth: CGFloat = 1
    static let rowFont = Font.system(size: 13, weight: .regular)
    static let rowSpacing: CGFloat = 12
    static let rowHorizontalInset: CGFloat = 14
    /// Two-line slider rows size to their content instead of `rowHeight`;
    /// this keeps their total height visually in step with single-line rows
    /// in the same group.
    static let sliderRowVerticalPadding: CGFloat = 12

    /// Neutral (non-accent, non-destructive) button fill — the resting state
    /// of `HoldToConfirmButton`, which only turns red as it fills.
    static let neutralButtonFill = adaptiveColor(
        dark: NSColor(white: 1, alpha: 0.14),
        light: NSColor(white: 0, alpha: 0.10)
    )
    static let destructiveFill = Color(red: 0xE0 / 255, green: 0x3B / 255, blue: 0x2F / 255)

    /// Centered empty/locked-state block (icon, caption, action button).
    static let emptyStateIconSize: CGFloat = 34
    static let emptyStateSpacing: CGFloat = 12
    static let emptyStateMinHeight: CGFloat = 340
    /// Crossfade between the locked and unlocked states of the Password page.
    static let stateTransitionAnimation = Animation.easeInOut(duration: 0.28)

    /// Taller card used by multi-option pickers (e.g. Unlock Animation).
    static let optionCardVerticalPadding: CGFloat = 14
    static let optionPreviewHeight: CGFloat = 58
    static let optionPreviewCornerRadius: CGFloat = 13
    static let optionPreviewFill = adaptiveColor(
        dark: NSColor(white: 1, alpha: 0.05),
        light: NSColor(white: 0, alpha: 0.05)
    )
    /// Fill for trailing menu/picker pills inside settings rows — stronger
    /// than `optionPreviewFill` so it still reads against `rowColor`.
    static let pickerPillFill = adaptiveColor(
        dark: NSColor(white: 1, alpha: 0.05),
        light: NSColor(white: 0, alpha: 0.10)
    )
    /// Accent wash over `optionPreviewFill` when the tile is selected.
    static let optionPreviewSelectedTintOpacity: CGFloat = 0.12
    static let optionLabelFont = Font.system(size: 12, weight: .medium)
    /// Blue selection ring sits this far outside the preview tile's edge.
    static let optionSelectionOutset: CGFloat = 2.5
    static let optionSelectionStrokeWidth: CGFloat = 3.5
    static let optionItemSpacing: CGFloat = 10
    /// Zero-offset soft edge so the preview tiles lift evenly on all sides.
    static let optionPreviewShadowColor = Color.black.opacity(0.15)
    static let optionPreviewShadowRadius: CGFloat = 4
    /// Dark-mode-only ring drawn just outside the rowBorder stroke.
    /// Clear in light mode so the overlay can stay unconditional.
    static let optionPreviewOuterStroke = adaptiveColor(
        dark: NSColor(white: 0.1, alpha: 0.6),
        light: NSColor(white: 0, alpha: 0)
    )
    static let optionPreviewOuterStrokeWidth: CGFloat = 1
    static let optionPreviewBorderWidth: CGFloat = 1
    static let sectionTitleFont = Font.system(size: 13, weight: .medium)
    static let sectionTitleHorizontalInset: CGFloat = 10
    static let sectionTitleVerticalPadding: CGFloat = 8

    static let contentHorizontalPadding: CGFloat = 16

    // MARK: - Capture-quality tick strip (Your Face)
    //
    // One tick per stored sample, colored by `FaceSample.QualityTier`.
    // Fixed literals rather than `adaptiveColor`, for the same reason
    // GlanceTheme's status dots are: red/amber/green are semantic, and read
    // correctly against both the dark and the light content panel.

    static let qualityPoorColor = Color(red: 0xFF / 255, green: 0x54 / 255, blue: 0x54 / 255)
    static let qualityFairColor = Color(red: 0xFF / 255, green: 0xBE / 255, blue: 0x54 / 255)
    static let qualityGoodColor = Color(red: 0x85 / 255, green: 0xFF / 255, blue: 0x77 / 255)
    /// Samples with no recorded score — enrollments predating per-sample
    /// quality. Deliberately neutral: unrated is not the same as poor.
    static let qualityUnratedColor = adaptiveColor(
        dark: NSColor(white: 1, alpha: 0.22),
        light: NSColor(white: 0, alpha: 0.20)
    )

    static let qualityTickWidth: CGFloat = 3.5
    static let qualityTickSpacing: CGFloat = 5.5
    static let qualityTickHeight: CGFloat = 26
    /// Caps the strip so an identity with an unusual number of samples (Face
    /// Lab's manual capture button is unbounded) compresses its ticks rather
    /// than running off the card.
    static let qualityStripMaxWidth: CGFloat = 250

    static let buttonBackgroundColor = Color(red: 0x3F / 255, green: 0x3F / 255, blue: 0x3F / 255)

    static let headerHeight: CGFloat = 40

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
