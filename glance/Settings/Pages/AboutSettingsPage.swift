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
        VStack(spacing: 2) {
            // Plain imageset (Assets.xcassets/appicon), not an app-icon
            // catalog entry — those live in a restricted namespace
            // `Image(_:)` can't resolve, which is what made the previous
            // two approaches here (Image("GlanceIcon"), then
            // NSApp.applicationIconImage) both show a blank placeholder.
            Image("appicon")
                .resizable()
                .frame(width: 80, height: 80)
                .padding(.top, 16)
                .padding(.bottom, 8)

            Text("Glance")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(SettingsMetrics.textPrimary)

            Text(versionString)
                .font(.system(size: 12))
                .foregroundStyle(SettingsMetrics.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 16)

        SettingsGroup {
            SettingsActionRowContent(
                title: "Check for Updates",
                buttonTitle: "Check",
                isEnabled: false
            ) {}

            SettingsGroupDivider()

            SettingsRowContent(title: "Automatically check for updates") {
                GlanceToggle(isOn: $settings.autoCheckForUpdates)
            }

            SettingsGroupDivider()

            SettingsActionRowContent(
                title: "Send Feedback",
                buttonTitle: "Send"
            ) {
                // TODO: point this at the real feedback destination once one exists.
                if let url = URL(string: "https://glance.app/feedback") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}
