//
//  AboutSettingsPage.swift
//  glance
//

import SwiftUI
import AppKit

struct AboutSettingsPage: View {
    @Bindable var updater: UpdaterController
    let environment: AppEnvironment

    /// Secret-tap state for revealing the Debug/Face Lab sidebar section —
    /// see `AppEnvironment.isDebugSectionRevealed`. `lastTapDate` is what
    /// makes this "5 times *consecutively*" rather than "5 times ever": a
    /// pause of more than a second resets the count, so absent-minded
    /// clicking around the About page over time can't accidentally trip it.
    @State private var iconTapCount = 0
    @State private var lastTapDate: Date?
    private let requiredTapCount = 5
    private let tapResetInterval: TimeInterval = 1.0

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
                .contentShape(Rectangle())
                .onTapGesture(perform: handleIconTap)

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
                isEnabled: updater.canCheckForUpdates
            ) {
                updater.checkForUpdates()
            }

            SettingsGroupDivider()

            SettingsRowContent(title: "Automatically check for updates") {
                GlanceToggle(isOn: $updater.automaticallyChecksForUpdates)
            }

            SettingsGroupDivider()

            SettingsActionRowContent(
                title: "Send Feedback",
                buttonTitle: "Send"
            ) {
                // TODO: point this at the real feedback destination once one exists.
                if let url = URL(string: "https://tryglance.app/feedback") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }

    private func handleIconTap() {
        let now = Date()
        if let lastTapDate, now.timeIntervalSince(lastTapDate) > tapResetInterval {
            iconTapCount = 0
        }
        lastTapDate = now
        iconTapCount += 1
        guard iconTapCount >= requiredTapCount else { return }
        iconTapCount = 0
        environment.isDebugSectionRevealed = true
    }
}
