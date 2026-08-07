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
    /// glow" the header used to show). Adapts to the system appearance via
    /// `adaptiveColor`, unlike the rest of this file's colors, which are
    /// still dark-only — see the type's doc comment.
    static let contentBackgroundColor = adaptiveColor(
        dark: NSColor(red: 0x18 / 255, green: 0x18 / 255, blue: 0x18 / 255, alpha: 1),
        light: .white
    )

    /// The sidebar's fill: the same per-appearance color as the content
    /// panel, but translucent, so the sidebar still reads as a distinct,
    /// lighter layer floating over `VisualEffectView`'s blur rather than a
    /// second flat card butted up against the first.
    static let sidebarBackgroundColor = adaptiveColor(
        dark: NSColor(red: 0x33 / 255, green: 0x33 / 255, blue: 0x33 / 255, alpha: 0.35),
        light: NSColor(white: 1, alpha: 0.55)
    )

    /// Gap between the content panel and every window edge — including the
    /// sidebar seam — now that the panel floats as its own card instead of
    /// sitting flush against the window frame.
    static let contentOuterSpacing: CGFloat = 8
    static let contentShadowColor = Color.black.opacity(0.12)
    static let contentShadowRadius: CGFloat = 12

    static let selectedPillRadius: CGFloat = 11
    static let selectedPillColor = Color.white.opacity(0.06)

    static let sidebarItemHeight: CGFloat = 32
    static let sidebarSectionSpacing: CGFloat = 8
    static let sidebarItemFont = Font.system(size: 14, weight: .medium)
    static let sectionHeaderFont = Font.system(size: 11, weight: .semibold)
    static let contentTitleFont = Font.system(size: 18, weight: .medium)

    static let textPrimary = Color(red: 0xEE / 255, green: 0xEE / 255, blue: 0xEE / 255)
    static let textSecondary = Color(red: 0xBF / 255, green: 0xBF / 255, blue: 0xBF / 255)

    static let rowHeight: CGFloat = 50
    static let rowRadius: CGFloat = 17
    static let rowColor = Color.white.opacity(0.05)
    static let rowBorder = Color.white.opacity(0.07)
    static let rowFont = Font.system(size: 15, weight: .medium)
    static let rowSpacing: CGFloat = 12
    static let rowHorizontalInset: CGFloat = 19

    static let contentHorizontalPadding: CGFloat = 20
    static let headerHeight: CGFloat = 50

    /// Wraps an `NSColor(name:dynamicProvider:)` so a color can track the
    /// system appearance rather than being fixed at whatever was true when
    /// this enum was evaluated. Every other color in this file is a plain
    /// `Color` literal and stays dark-only regardless of system appearance —
    /// only `contentBackgroundColor` and `sidebarBackgroundColor` currently
    /// use this, per an explicit request to make just the panel/sidebar
    /// fills follow light/dark mode. Text and row colors were left alone, so
    /// light mode currently has low contrast against a white content panel —
    /// flagged, not fixed, since re-theming those wasn't asked for.
    private static func adaptiveColor(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}
