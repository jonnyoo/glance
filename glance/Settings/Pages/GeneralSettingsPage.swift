//
//  GeneralSettingsPage.swift
//  glance
//

import SwiftUI

struct GeneralSettingsPage: View {
    @Bindable var pocController: POCController
    @Bindable var coordinator: FaceUnlockCoordinator
    @Bindable private var settings = GlanceSettings.shared

    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    @State private var launchAtLoginError: String?

    var body: some View {
        SettingsGroup {
            SettingsRowContent(title: "Launch at login") {
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
            SettingsGroupDivider()
            SettingsRowContent(title: "Enable Face Unlock") {
                GlanceToggle(isOn: $coordinator.isEnabled)
            }
            SettingsGroupDivider()
            SettingsRowContent(title: "Unlock on wake") {
                GlanceToggle(isOn: $pocController.autoInjectOnLock)
            }
        }
        if let launchAtLoginError {
            SettingsCaption(text: launchAtLoginError)
        }

        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(text: "Unlock Animation")
            UnlockAnimationPicker(selection: $settings.unlockAnimationStyle)
        }
    }
}
