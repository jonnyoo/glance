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

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .yourFace: return "faceid"
        case .password: return "key.fill"
        case .camera: return "camera.fill"
        case .recognition: return "wand.and.stars"
        case .about: return "info.circle"
        case .debugCredentials: return "lock.shield"
        case .debugFaceLab: return "flask"
        case .debugFaceUnlock: return "faceid"
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
        case .general:
            return [
                Color(red: 0x9C / 255, green: 0x9C / 255, blue: 0xA1 / 255), // top: light grey
                Color(red: 0x6E / 255, green: 0x6E / 255, blue: 0x73 / 255), // bottom: grey
            ]
        case .yourFace: return [GlanceTheme.accent, GlanceTheme.accent]
        case .password: return [GlanceTheme.accent, GlanceTheme.accent]
        case .camera: return [GlanceTheme.accent, GlanceTheme.accent]
        case .recognition: return [GlanceTheme.accent, GlanceTheme.accent]
        case .about: return [GlanceTheme.accent, GlanceTheme.accent]
        case .debugCredentials: return [GlanceTheme.accent, GlanceTheme.accent]
        case .debugFaceLab: return [GlanceTheme.accent, GlanceTheme.accent]
        case .debugFaceUnlock: return [GlanceTheme.accent, GlanceTheme.accent]
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
