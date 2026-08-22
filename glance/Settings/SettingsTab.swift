//
//  SettingsTab.swift
//  glance
//
//  The sidebar's tab list and section grouping. DEBUG is the temporary
//  home for the pre-Settings debug console (Credentials / Face Lab / Face
//  Unlock) — kept only for ongoing testing, per Jonathan.
//

import SwiftUI

enum SettingsSection: String, CaseIterable, Hashable {
    case authentication = "Authentication"
    case glance = "Glance"
    case debug = "Debug"
}

enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general
    case yourFace
    case password
    case camera
    case recognition
    case about
    case debugCredentials
    case debugFaceLab
    case debugFaceUnlock

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .yourFace: return "Your Face"
        case .password: return "Password"
        case .camera: return "Camera"
        case .recognition: return "Recognition"
        case .about: return "About"
        case .debugCredentials: return "Credentials"
        case .debugFaceLab: return "Face Lab"
        case .debugFaceUnlock: return "Face Unlock"
        }
    }

    /// `.yourFace` uses a custom mark (`Assets.xcassets/YourFaceIcon`) —
    /// SF Symbols has no equivalent of it. Every other tab is a built-in
    /// symbol; see `SettingsTabIcon` for how `SettingsTabIconBadge` renders
    /// either kind identically otherwise.
    var icon: SettingsTabIcon {
        switch self {
        case .general: return .system("gearshape.fill")
        case .yourFace: return .asset("YourFaceIcon")
        case .password: return .system("lock.fill")
        case .camera: return .system("video.fill")
        case .recognition: return .system("sparkle")
        case .about: return .system("info.circle.fill")
        case .debugCredentials: return .system("lock.shield")
        case .debugFaceLab: return .system("flask")
        case .debugFaceUnlock: return .system("faceid")
        }
    }

    /// Top-to-bottom gradient stops for this tab's icon badge
    /// (`SettingsTabIconBadge`, drawn behind the glyph in both the sidebar
    /// row and the page header) — the small colored squircle System
    /// Settings gives each category, several of which (General's gear,
    /// among others) are themselves a subtle vertical gradient rather than
    /// a flat fill.
    ///
    /// Two colors, read top-first: `SettingsTabIconBadge` always renders a
    /// `LinearGradient(colors:, startPoint: .top, endPoint: .bottom)`, so a
    /// flat tile (most tabs, for now) is just the same color listed twice —
    /// there's no separate "flat" case to keep in sync.
    ///
    /// To give a tab its own gradient later — e.g. one picked in Figma —
    /// change just its line below. Figma's own "Copy as CSS" on a gradient
    /// fill hands you a `linear-gradient(...)` string with each stop's hex
    /// already in order; for a straight-down (180deg) gradient that order
    /// matches this array directly (top stop first). If a gradient has more
    /// than two stops, or stops that aren't evenly spaced, swap this
    /// property's return type for `[Gradient.Stop]` and pass
    /// `Gradient(stops:)` into `SettingsTabIconBadge` instead — see its doc
    /// comment.
    var badgeGradientColors: [Color] {
        switch self {
        case .general: return GlanceTheme.badgeGeneral
        case .yourFace: return GlanceTheme.badgeYourFace
        case .password: return GlanceTheme.badgePassword
        case .camera: return GlanceTheme.badgeCamera
        case .recognition: return GlanceTheme.badgeRecognition
        case .about: return GlanceTheme.badgeGeneral
        case .debugCredentials: return GlanceTheme.badgeGeneral
        case .debugFaceLab: return GlanceTheme.badgeGeneral
        case .debugFaceUnlock: return GlanceTheme.badgeGeneral
        }
    }

    /// Section this tab is grouped under. `nil` renders with no header,
    /// matching the Figma design's ungrouped "General" row at the top.
    var section: SettingsSection? {
        switch self {
        case .general: return nil
        case .yourFace, .password, .camera, .recognition: return .authentication
        case .about: return .glance
        case .debugCredentials, .debugFaceLab, .debugFaceUnlock: return .debug
        }
    }

    /// Sections in sidebar display order, including the ungrouped leading
    /// section (`nil`).
    static let sectionOrder: [SettingsSection?] = [nil, .authentication, .glance, .debug]

    static func tabs(in section: SettingsSection?) -> [SettingsTab] {
        allCases.filter { $0.section == section }
    }
}
