//
//  AboutSettingsPage.swift
//  glance
//

import SwiftUI
import AppKit

struct AboutSettingsPage: View {
    @Bindable private var settings = GlanceSettings.shared

    private var versionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage ?? NSImage())
                .resizable()
                .frame(width: 96, height: 96)
                .padding(.top, 12)

            Text("Glance")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(SettingsMetrics.textPrimary)

            Text(versionString)
                .font(.system(size: 12))
                .foregroundStyle(SettingsMetrics.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 16)

        SettingsActionRow(
            title: "Check for Updates",
            subtitle: "Not available yet — coming soon",
            buttonTitle: "Check Now",
            isEnabled: false
        ) {}

        SettingsRow(title: "Automatically check for updates") {
            GlanceToggle(isOn: $settings.autoCheckForUpdates)
        }

        SettingsActionRow(
            title: "Send Feedback",
            subtitle: "Report a bug or share an idea",
            buttonTitle: "Send Feedback"
        ) {
            // TODO: point this at the real feedback destination once one exists.
            if let url = URL(string: "https://glance.app/feedback") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
