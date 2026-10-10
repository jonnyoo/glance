//
//  SettingsTab.swift
//  glance
//
//  The tab bar's tab list. Debug-only Face Lab — the remaining live test
//  harness, kept for ongoing tuning — is appended only once revealed.
//

import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general
    case yourFace
    case password
    case camera
    case recognition
    case appLock
    case about
    case debugFaceLab

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .yourFace: return "Face"
        case .password: return "Password"
        case .camera: return "Camera"
        case .recognition: return "Recognition"
        case .appLock: return "App Lock"
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
        case .appLock: return .system("lock.shield.fill")
        case .about: return .system("info.circle.fill")
        case .debugFaceLab: return .system("flask")
        }
    }

    /// Tabs in tab bar order, minus `.debugFaceLab` unless it's been
    /// unlocked this launch — see `AppEnvironment.isDebugSectionRevealed`.
    static func visibleTabs(includingDebug: Bool) -> [SettingsTab] {
        includingDebug ? allCases : allCases.filter { $0 != .debugFaceLab }
    }
}
