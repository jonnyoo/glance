//
//  AppLockSettingsPage.swift
//  glance
//
//  Settings page for the App Lock feature — lets the user toggle App Lock,
//  manage which apps are locked, and configure the relock policy.
//

import SwiftUI

struct AppLockSettingsPage: View {
    @Bindable var pocController: POCController
    @Bindable private var settings = GlanceSettings.shared
    @Bindable private var store = LockedAppStore.shared

    @State private var isUnlocking = false
    @State private var sessionError: String?
    @State private var showingAppPicker = false
    @State private var installedApps: [DiscoveredApp] = []
    @State private var searchText = ""

    private var isSessionUnlocked: Bool { pocController.isSessionUnlocked }

    var body: some View {
        ZStack(alignment: .top) {
            lockedState
                .opacity(isSessionUnlocked ? 0 : 1)
                .allowsHitTesting(!isSessionUnlocked)
                .accessibilityHidden(isSessionUnlocked)

            unlockedState
                .opacity(isSessionUnlocked ? 1 : 0)
                .allowsHitTesting(isSessionUnlocked)
                .accessibilityHidden(!isSessionUnlocked)
        }
        .animation(SettingsMetrics.stateTransitionAnimation, value: isSessionUnlocked)
        .onAppear { pocController.refreshCredentialStatus() }
    }

    // MARK: - Locked

    private var lockedState: some View {
        SettingsEmptyStateView(
            icon: "lock.app.fill",
            message: "Unlock to manage App Lock",
            buttonTitle: isUnlocking ? "Authenticating…" : "Unlock session",
            isButtonEnabled: !isUnlocking,
            caption: sessionError,
            action: unlock
        )
    }

    // MARK: - Unlocked

    private var unlockedState: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingsGroup {
                SettingsRowContent(
                    title: "App Lock",
                    info: "Lock chosen apps behind face verification. When you open a locked app, iFace verifies your face before granting access."
                ) {
                    GlanceToggle(isOn: $store.isEnabled)
                }
            }

            if store.isEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsSectionTitle(text: "Locked Apps")

                    if store.apps.isEmpty {
                        emptyAppsState
                    } else {
                        SettingsGroup {
                            ForEach(Array(store.apps.enumerated()), id: \.element.bundleID) { index, app in
                                if index > 0 {
                                    SettingsGroupDivider()
                                }
                                lockedAppRow(app)
                            }
                        }

                        Button(action: { loadAndShowAppPicker() }) {
                            HStack(spacing: 6) {
                                Image(systemName: "plus.circle.fill")
                                    .font(.system(size: 14))
                                Text("Add App")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundStyle(GlanceTheme.accent)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, SettingsMetrics.sectionTitleHorizontalInset)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    SettingsSectionTitle(text: "Default Relock Policy")
                    SettingsGroup {
                        relockPolicyPicker
                    }
                    SettingsCaption(text: "Controls when apps re-lock after being unlocked. You can override per app.")
                }
            }
        }
        .sheet(isPresented: $showingAppPicker) {
            appPickerSheet
        }
    }

    // MARK: - Locked App Row

    private func lockedAppRow(_ app: LockedApp) -> some View {
        HStack(spacing: 12) {
            if let icon = appIcon(for: app.bundleID) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 28, height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            } else {
                Image(systemName: "app.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(SettingsMetrics.textTertiary)
                    .frame(width: 28, height: 28)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(app.name)
                    .font(SettingsMetrics.rowFont)
                    .foregroundStyle(SettingsMetrics.textPrimary)
                    .lineLimit(1)
                Text(app.policy.title)
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsMetrics.textTertiary)
            }

            Spacer(minLength: 8)

            relockPolicyMenu(for: app)

            Button(action: { store.remove(bundleID: app.bundleID) }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .foregroundStyle(SettingsMetrics.textTertiary)
            }
            .buttonStyle(.plain)
            .help("Remove from locked apps")
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
        .frame(minHeight: SettingsMetrics.rowHeight + 6)
    }

    private func relockPolicyMenu(for app: LockedApp) -> some View {
        SettingsMenuPickerPill(label: app.policy.shortTitle) {
            Button("Every time") {
                store.updatePolicy(for: app.bundleID, to: .everyTime)
            }
            Button("After 1 min") {
                store.updatePolicy(for: app.bundleID, to: .afterMinutes(1))
            }
            Button("After 5 min") {
                store.updatePolicy(for: app.bundleID, to: .afterMinutes(5))
            }
            Button("After 15 min") {
                store.updatePolicy(for: app.bundleID, to: .afterMinutes(15))
            }
            Button("After 30 min") {
                store.updatePolicy(for: app.bundleID, to: .afterMinutes(30))
            }
            Divider()
            Button("After 1 min away") {
                store.updatePolicy(for: app.bundleID, to: .afterFocusLossMinutes(1))
            }
            Button("After 5 min away") {
                store.updatePolicy(for: app.bundleID, to: .afterFocusLossMinutes(5))
            }
        }
    }

    // MARK: - Default Relock Policy

    private var relockPolicyPicker: some View {
        SettingsRowContent(title: "Default policy") {
            SettingsMenuPickerPill(label: settings.defaultRelockPolicy.title) {
                Button("Every time") {
                    settings.defaultRelockPolicy = .everyTime
                }
                Button("After 1 minute") {
                    settings.defaultRelockPolicy = .afterMinutes(1)
                }
                Button("After 5 minutes") {
                    settings.defaultRelockPolicy = .afterMinutes(5)
                }
                Button("After 15 minutes") {
                    settings.defaultRelockPolicy = .afterMinutes(15)
                }
                Button("After 30 minutes") {
                    settings.defaultRelockPolicy = .afterMinutes(30)
                }
                Divider()
                Button("After 1 min of inactivity") {
                    settings.defaultRelockPolicy = .afterFocusLossMinutes(1)
                }
                Button("After 5 min of inactivity") {
                    settings.defaultRelockPolicy = .afterFocusLossMinutes(5)
                }
            }
        }
    }

    // MARK: - Empty State

    private var emptyAppsState: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.app.fill")
                .font(.system(size: 28))
                .foregroundStyle(SettingsMetrics.textTertiary)
            Text("No apps locked yet")
                .font(SettingsMetrics.rowFont)
                .foregroundStyle(SettingsMetrics.textSecondary)
            SettingsPrimaryButton(title: "Add App", action: { loadAndShowAppPicker() })
        }
        .frame(maxWidth: .infinity, minHeight: 120)
        .background(SettingsMetrics.rowColor)
        .overlay(
            RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius)
                .strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
        )
        .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius))
    }

    // MARK: - App Picker Sheet

    private var appPickerSheet: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Choose Apps to Lock")
                    .font(.headline)
                Spacer()
                Button("Done") { showingAppPicker = false }
                    .buttonStyle(.plain)
                    .foregroundStyle(GlanceTheme.accent)
            }
            .padding()

            // Search
            TextField("Search apps…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal)
                .padding(.bottom, 8)

            Divider()

            // App list
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(filteredApps, id: \.bundleID) { app in
                        appPickerRow(app)
                    }
                }
                .padding(.vertical, 8)
            }
        }
        .frame(width: 380, height: 460)
    }

    private var filteredApps: [DiscoveredApp] {
        let apps = installedApps.filter { !store.isLocked($0.bundleID) }
        if searchText.isEmpty { return apps }
        return apps.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private func appPickerRow(_ app: DiscoveredApp) -> some View {
        Button(action: {
            store.add(LockedApp(
                bundleID: app.bundleID,
                name: app.name,
                policy: settings.defaultRelockPolicy
            ))
        }) {
            HStack(spacing: 12) {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                Text(app.name)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer()

                Image(systemName: "plus.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(GlanceTheme.accent)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func unlock() {
        isUnlocking = true
        sessionError = nil
        Task {
            await pocController.unlockSession()
            sessionError = pocController.sessionError
            isUnlocking = false
        }
    }

    private func loadAndShowAppPicker() {
        Task.detached(priority: .userInitiated) {
            let apps = InstalledApps.discover()
            await MainActor.run {
                installedApps = apps
                searchText = ""
                showingAppPicker = true
            }
        }
    }

    private func appIcon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
