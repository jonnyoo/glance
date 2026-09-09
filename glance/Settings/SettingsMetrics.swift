//
//  SettingsMetrics.swift
//  glance
//
//  Design tokens for the Settings window — one file to tune sizing/color
//  in rather than scattered literals.
//

import SwiftUI

enum SettingsMetrics {
    static let windowSize = CGSize(width: 620, height: 650)
    /// No `outerCornerRadius` token — the window's outer corner is AppKit's
    /// own native mask (see WindowConfiguringView), not a hardcoded clip.
    ///
    /// Vertical strip at the top of the sidebar left empty for the window's
    /// real traffic lights, which AppKit draws over our content.
    static let trafficLightBandHeight: CGFloat = 52
    static let contentCornerRadius: CGFloat = 19
    static let sidebarWidth: CGFloat = 190

    /// Solid, not translucent, so it reads as an opaque card rather than
    /// picking up bleed-through from `VisualEffectView`'s materials.
    static let contentBackgroundColor = adaptiveColor(
        dark: NSColor(red: 0x10 / 255, green: 0x10 / 255, blue: 0x10 / 255, alpha: 0.25),
        light: NSColor(white: 1, alpha: 0.25)
    )

    /// Same per-appearance color as the content panel, but translucent, so
    /// the sidebar reads as a distinct layer over `VisualEffectView`'s blur.
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
    /// Opaque fill for the panel's shadow-casting underlay, so the drop
    /// shadow follows the card outline instead of every row's silhouette.
    static let contentShadowFill = adaptiveColor(
        dark: NSColor(red: 0x10 / 255, green: 0x10 / 255, blue: 0x10 / 255, alpha: 0.2),
        light: NSColor(white: 1, alpha: 0.2)
    )

    /// A hairline edge around the content panel — an actual grey in both
    /// appearances, unlike `rowBorder`/`selectedPillColor` elsewhere, which
    /// fake "grey" via a translucent black or white tint.
    static let contentStrokeColor = adaptiveColor(
        dark: NSColor(white: 0.5, alpha: 0.3),
        light: NSColor(white: 0.5, alpha: 0.3)
    )

    static let selectedPillRadius: CGFloat = 11
    /// Light mode flips the tint direction from dark mode's lightness to a
    /// touch of darkness, since a white tint is invisible over the light fill.
    static let selectedPillColor = adaptiveColor(
        dark: NSColor(white: 1, alpha: 0.06),
        light: NSColor(white: 1, alpha: 0.4)
    )

    static let sidebarItemHeight: CGFloat = 36
    static let sidebarSectionSpacing: CGFloat = 8
    /// Deliberately asymmetric: pulled in on the right to visually balance
    /// against the left at equal insets.
    static let sidebarContentLeadingInset: CGFloat = 12
    static let sidebarContentTrailingInset: CGFloat = 2
    static let sidebarItemFont = Font.system(size: 13, weight: .regular)
    static let sectionHeaderFont = Font.system(size: 13, weight: .medium)
    static let contentTitleFont = Font.system(size: 15, weight: .medium)

    /// Light-mode values match the exact resolved alpha AppKit's own
    /// `NSColor.labelColor`/`.secondaryLabelColor` use (`black @ 0.85`/`0.50`),
    /// so text reads with the same contrast as every other native app.
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
    /// Same tint-flip logic as `selectedPillColor` — light mode goes
    /// slightly darker than the page instead of lighter.
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
    /// Taller variant for `UnlockAnimationPicker` — its artwork needs real
    /// room to read as an actual pill/panel shape, not a small swatch.
    static let unlockAnimationPreviewHeight: CGFloat = 108
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
    static let optionItemSpacing: CGFloat = 15
    /// Zero-offset soft edge so the preview tiles lift evenly on all sides.
    static let optionPreviewShadowColor = Color.black.opacity(0.15)
    static let optionPreviewShadowRadius: CGFloat = 4
    /// Dark-mode-only ring drawn just outside the rowBorder stroke.
    /// Clear in light mode so the overlay can stay unconditional.
    static let optionPreviewOuterStroke = adaptiveColor(
        dark: NSColor(white: 0.1, alpha: 0.35),
        light: NSColor(white: 0, alpha: 0)
    )
    static let optionPreviewOuterStrokeWidth: CGFloat = 1
    static let optionPreviewBorderWidth: CGFloat = 1
    static let sectionTitleFont = Font.system(size: 13, weight: .medium)
    static let sectionTitleHorizontalInset: CGFloat = 10
    static let sectionTitleVerticalPadding: CGFloat = 8

    static let contentHorizontalPadding: CGFloat = 16

    // MARK: - Tab icon badges
    //
    // The small colored squircle behind each tab's glyph. Corner radius is
    // kept proportional to size (~28%, matching macOS's own rounded-square
    // icon tiles) so both sizes read as the same shape.

    static let sidebarIconBadgeSize: CGFloat = 23
    static let sidebarIconBadgeCornerRadius: CGFloat = 7
    static let sidebarIconBadgeGlyphSize: CGFloat = 13.5

    static let headerIconBadgeSize: CGFloat = 23
    static let headerIconBadgeCornerRadius: CGFloat = 7
    static let headerIconBadgeGlyphSize: CGFloat = 13.5


    // MARK: - Capture-quality tick strip (Your Face)
    //
    // One tick per stored sample, colored by `FaceSample.QualityTier`.
    // Fixed literals rather than `adaptiveColor` — semantic red/amber/green
    // that reads correctly against both dark and light content panels.

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
    /// Caps the strip so an identity with an unusual number of samples
    /// compresses its ticks rather than running off the card.
    static let qualityStripMaxWidth: CGFloat = 250

    static let buttonBackgroundColor = Color(red: 0x3F / 255, green: 0x3F / 255, blue: 0x3F / 255)

    static let headerHeight: CGFloat = 40

    /// No blur or scrim sits behind the header — every tint/blur approach
    /// tried either read as an "extra white band" or couldn't render inside
    /// SwiftUI's hosting view over native controls. Don't re-attempt without
    /// an explicit ask.

    /// Resolves live against the current system appearance rather than a
    /// value fixed at evaluation time.
    private static func adaptiveColor(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}
