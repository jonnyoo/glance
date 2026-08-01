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
    /// Matches macOS 26 Tahoe's own native window corner radius. Measured
    /// empirically rather than guessed: `screencapture -o -l<windowID>` on
    /// System Settings preserves the window's alpha mask, and the traced
    /// top-left corner profile was least-squares fitted against `CALayer`
    /// corners rendered at 2x across radii. The best fit is **26pt with a
    /// *continuous* (squircle) curve** — sub-pixel RMSE, and clearly better
    /// than any circular radius, which can't reproduce the long flat tail
    /// where the curve merges into the straight edge.
    ///
    /// The curve style matters as much as the number here: at the same
    /// radius a circular corner turns much more abruptly, which is what
    /// reads as "not quite native". Always pair this with
    /// `RoundedRectangle(cornerRadius:style: .continuous)`.
    static let outerCornerRadius: CGFloat = 27
    static let contentCornerRadius: CGFloat = 17.5
    static let sidebarWidth: CGFloat = 190

    /// The whole-window base tint. The sidebar shows this alone; the content
    /// panel stacks `contentOverlayColor` on top of it — that extra layer is
    /// what makes the content panel read as *less* translucent than the
    /// sidebar, exactly as requested.
    static let baseLayerColor = Color(red: 16 / 255, green: 16 / 255, blue: 16 / 255).opacity(0.45)
    static let contentOverlayColor = Color(red: 16 / 255, green: 16 / 255, blue: 16 / 255).opacity(0.38)

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
}
