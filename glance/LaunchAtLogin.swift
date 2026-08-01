//
//  LaunchAtLogin.swift
//  glance
//
//  Thin wrapper around SMAppService.mainApp. Deliberately not persisted via
//  GlanceSettings — SMAppService's own registration status IS the source of
//  truth (survives relaunch at the OS level), so mirroring it into
//  UserDefaults would just create a second copy that can drift out of sync.
//

import Foundation
import ServiceManagement

enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            guard SMAppService.mainApp.status != .enabled else { return }
            try SMAppService.mainApp.register()
        } else {
            guard SMAppService.mainApp.status == .enabled else { return }
            try SMAppService.mainApp.unregister()
        }
    }
}
