//
//  AppLockSettingsPage.swift
//  glance
//
//  Pick which apps need your face before they show their windows, and when they lock again.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AppLockSettingsPage: View {
    @Bindable private var settings = GlanceSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingsCaption(text: String(localized: "A locked app stays covered until Glance recognizes your face, or you use Touch ID or your password. It keeps casual onlookers out; it doesn't replace a separate macOS user account."))
                .padding(.horizontal, SettingsMetrics.sectionTitleHorizontalInset)

            SettingsGroup {
                SettingsRowContent(title: String(localized: "Lock again")) {
                    SettingsMenuPickerPill(label: Self.title(for: settings.appLockRelockPolicy)) {
                        ForEach(AppLockRelockPolicy.allCases) { policy in
                            Button(Self.title(for: policy)) { settings.appLockRelockPolicy = policy }
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionTitle(text: String(localized: "Locked apps"))
                SettingsGroup {
                    ForEach(settings.lockedAppBundleIDs, id: \.self) { bundleID in
                        LockedAppRow(bundleID: bundleID) {
                            settings.lockedAppBundleIDs.removeAll { $0 == bundleID }
                        }
                        SettingsGroupDivider()
                    }
                    SettingsRowContent(
                        title: settings.lockedAppBundleIDs.isEmpty
                            ? String(localized: "No apps are locked yet.")
                            : String(localized: "Lock another app")
                    ) {
                        SettingsPrimaryButton(title: String(localized: "Add…"), compact: true, action: addApps)
                    }
                }
            }
        }
    }

    private func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.prompt = String(localized: "Lock")
        guard panel.runModal() == .OK else { return }
        let ownBundleID = Bundle.main.bundleIdentifier
        for url in panel.urls {
            guard let bundleID = Bundle(url: url)?.bundleIdentifier, bundleID != ownBundleID,
                  !settings.lockedAppBundleIDs.contains(bundleID) else { continue }
            settings.lockedAppBundleIDs.append(bundleID)
        }
    }

    private static func title(for policy: AppLockRelockPolicy) -> String {
        switch policy {
        case .onQuit: return String(localized: "When the app quits")
        case .afterFiveMinutesAway: return String(localized: "5 minutes after switching away")
        case .everyActivation: return String(localized: "Every time it opens")
        }
    }
}

/// Icon, name and a remove button for one locked app. Falls back to the bundle ID if the app is no longer installed.
private struct LockedAppRow: View {
    let bundleID: String
    let onRemove: () -> Void

    var body: some View {
        let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        HStack(spacing: 10) {
            Image(nsImage: url.map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage(named: NSImage.applicationIconName) ?? NSImage())
                .resizable()
                .frame(width: 28, height: 28)
            Text(url.map { FileManager.default.displayName(atPath: $0.path) } ?? bundleID)
                .font(SettingsMetrics.rowFont)
                .foregroundStyle(SettingsMetrics.textPrimary)
            Spacer(minLength: 8)
            Button(action: onRemove) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsMetrics.textPrimary)
                    .frame(width: 28, height: 28)
                    .background(SettingsMetrics.neutralButtonFill)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Stop locking this app"))
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
        .frame(minHeight: SettingsMetrics.rowHeight)
    }
}
