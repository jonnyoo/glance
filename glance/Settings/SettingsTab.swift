//
//  SettingsTab.swift
//  glance
//
//  The sidebar's tab list and section grouping. DEBUG is the temporary
//  home for the pre-Settings debug console (Credentials / Face Lab / Face
//  Unlock) — kept only for ongoing testing, per Jonathan.
//

import Foundation

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
