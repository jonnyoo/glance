//
//  SettingsTab.swift
//  glance
//
//  The sidebar's tab list and section grouping. DEBUG currently holds only
//  Face Lab — the remaining live test harness, kept for ongoing tuning.
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
    case debugFaceLab

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .yourFace: return "Your Face"
        case .password: return "Password"
        case .camera: return "Camera"
        case .recognition: return "Recognition"
        case .about: return "About"
        case .debugFaceLab: return "Face Lab"
        }
    }

    /// `.yourFace` uses a custom mark — SF Symbols has no equivalent.
    /// Every other tab is a built-in symbol; see `SettingsTabIcon`.
    var icon: SettingsTabIcon {
        switch self {
        case .general: return .system("gearshape.fill")
        case .yourFace: return .asset("YourFaceIcon")
        case .password: return .system("lock.fill")
        case .camera: return .system("video.fill")
        case .recognition: return .system("sparkle")
        case .about: return .system("info.circle.fill")
        case .debugFaceLab: return .system("flask")
        }
    }

    /// Top-to-bottom gradient stops for this tab's icon badge
    /// (`SettingsTabIconBadge`). Two colors, read top-first; a flat tile is
    /// just the same color listed twice.
    var badgeGradientColors: [Color] {
        switch self {
        case .general: return GlanceTheme.badgeGeneral
        case .yourFace: return GlanceTheme.badgeYourFace
        case .password: return GlanceTheme.badgePassword
        case .camera: return GlanceTheme.badgeCamera
        case .recognition: return GlanceTheme.badgeRecognition
        case .about: return GlanceTheme.badgeGeneral
        case .debugFaceLab: return GlanceTheme.badgeGeneral
        }
    }

    /// Section this tab is grouped under. `nil` renders with no header —
    /// the ungrouped "General" row at the top.
    var section: SettingsSection? {
        switch self {
        case .general: return nil
        case .yourFace, .password, .camera, .recognition: return .authentication
        case .about: return .glance
        case .debugFaceLab: return .debug
        }
    }

    /// Sections in sidebar display order, including the ungrouped leading
    /// section (`nil`).
    static let sectionOrder: [SettingsSection?] = [nil, .authentication, .glance, .debug]

    /// `sectionOrder`, minus `.debug` unless it's been unlocked this launch
    /// — see `AppEnvironment.isDebugSectionRevealed`.
    static func sectionOrder(includingDebug: Bool) -> [SettingsSection?] {
        includingDebug ? sectionOrder : sectionOrder.filter { $0 != .debug }
    }

    static func tabs(in section: SettingsSection?) -> [SettingsTab] {
        allCases.filter { $0.section == section }
    }
}
