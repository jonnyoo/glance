//
//  SudoSettingsPage.swift
//  glance
//


import SwiftUI

struct SudoSettingsPage: View {
    @Bindable private var settings = GlanceSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingsGroup {
                SettingsRowContent(
                    title: "Authenticate sudo with Glance",
                    subtitle: settings.isSudoAuthenticationEnabled ? "Enabled" : "Disabled"
                ) {
                    GlanceToggle(isOn: $settings.isSudoAuthenticationEnabled)
                }
            }

            SettingsCaption(
                text: "Requires the Glance PAM module to be installed by an administrator. When this is off, Glance is unavailable, or face authentication fails, macOS continues to Touch ID or your password."
            )

            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionTitle(text: "Behaviour")
                SettingsGroup {
                    SettingsRowContent(
                        title: "Retry again on hover",
                        subtitle: "Hover the failed Glance animation to scan again"
                    ) {
                        GlanceToggle(isOn: $settings.retryOnHover)
                    }
                    SettingsGroupDivider()
                    SettingsRowContent(
                        title: "Auto retry again once",
                        subtitle: "Make one fresh attempt after an unsuccessful scan"
                    ) {
                        GlanceToggle(isOn: $settings.autoRetryOnce)
                    }
                }
            }
            SettingsCaption(text: "Retry preferences are shared with normal Face Unlock.")

            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionTitle(text: "How it works")
                SettingsGroup {
                    SettingsRowContent(
                        title: "Local requests only",
                        subtitle: "Remote sessions cannot use camera authentication"
                    ) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(SettingsMetrics.textSecondary)
                    }
                    SettingsGroupDivider()
                    SettingsRowContent(
                        title: "Liveness required",
                        subtitle: "Sudo always uses Glance’s strongest liveness check"
                    ) {
                        Image(systemName: "person.crop.circle.badge.checkmark")
                            .font(.system(size: 13))
                            .foregroundStyle(SettingsMetrics.textSecondary)
                    }
                    SettingsGroupDivider()
                    SettingsRowContent(
                        title: "System fallback preserved",
                        subtitle: "Used whenever Glance’s session is locked or a scan fails"
                    ) {
                        Image(systemName: "touchid")
                            .font(.system(size: 13))
                            .foregroundStyle(SettingsMetrics.textSecondary)
                    }
                }
            }
        }
    }
}
