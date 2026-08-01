//
//  GeneralSettingsPage.swift
//  glance
//

import SwiftUI

struct GeneralSettingsPage: View {
    @Bindable var pocController: POCController
    @Bindable var coordinator: FaceUnlockCoordinator

    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    @State private var launchAtLoginError: String?

    var body: some View {
        SettingsRow(title: "Launch at login") {
            GlanceToggle(isOn: Binding(
                get: { launchAtLoginEnabled },
                set: { newValue in
                    launchAtLoginEnabled = newValue
                    do {
                        try LaunchAtLogin.setEnabled(newValue)
                        launchAtLoginError = nil
                    } catch {
                        launchAtLoginEnabled = !newValue
                        launchAtLoginError = error.localizedDescription
                    }
                }
            ))
        }
        if let launchAtLoginError {
            SettingsCaption(text: launchAtLoginError)
        }

        SettingsRow(title: "Enable Face Unlock", subtitle: "Unlock your Mac by looking at it") {
            GlanceToggle(isOn: $coordinator.isEnabled)
        }

        SettingsRow(title: "Unlock on wake", subtitle: "Also try face unlock right after your Mac wakes") {
            GlanceToggle(isOn: $pocController.autoInjectOnLock)
        }

        SettingsRow(title: "Play unlock animation") {
            GlanceToggle(isOn: Binding(
                get: { GlanceSettings.shared.playUnlockAnimation },
                set: { GlanceSettings.shared.playUnlockAnimation = $0 }
            ))
        }
    }
}
