//
//  GeneralSettingsPage.swift
//  glance
//

import OSLog
import SwiftUI

struct GeneralSettingsPage: View {
    @Bindable var coordinator: FaceUnlockCoordinator
    @Bindable private var settings = GlanceSettings.shared

    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    @State private var launchAtLoginError: String?
    /// Refreshed on `didChangeScreenParametersNotification` so the picker
    /// reflects displays connecting/disconnecting while Settings is open.
    @State private var screens: [NSScreen] = NSScreen.screens
    /// Refreshed when the app regains focus, so granting the permission in
    /// System Settings clears the prompt below without a relaunch.
    @State private var inputMonitoring = SpaceKeyMonitor.inputMonitoringAccess

    private var needsInputMonitoring: Bool {
        settings.unlockTriggers.contains(.onSpace) && inputMonitoring != .granted
    }

    /// Dev-only: under Xcode the reading above is Xcode's permission, not
    /// glance's, so it's meaningless. See `SpaceKeyMonitor.isLaunchedByXcode`.
    private var hasInheritedXcodePermission: Bool {
        settings.unlockTriggers.contains(.onSpace) && SpaceKeyMonitor.isLaunchedByXcode
    }

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
            UnlockTriggerPicker(selection: $settings.unlockTriggers, isEnabled: coordinator.isEnabled)
            SettingsGroupDivider()
            displayPicker()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = NSScreen.screens
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            inputMonitoring = SpaceKeyMonitor.inputMonitoringAccess
        }
        .onChange(of: settings.unlockTriggers) { oldValue, newValue in
            // Only prompt on the transition into selecting "On space".
            SpaceKeyMonitor.log.info("unlockTriggers changed: old=\(String(describing: oldValue), privacy: .public) new=\(String(describing: newValue), privacy: .public) state=\(String(describing: inputMonitoring), privacy: .public)")
            if newValue.contains(.onSpace), !oldValue.contains(.onSpace), inputMonitoring != .granted {
                SpaceKeyMonitor.requestInputMonitoringAccess()
                // tccd flips notDetermined -> denied just after the call
                // returns, so re-read on the next beat rather than inline.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    inputMonitoring = SpaceKeyMonitor.inputMonitoringAccess
                }
            }
        }
        if let launchAtLoginError {
            SettingsCaption(text: launchAtLoginError)
        }
        if hasInheritedXcodePermission {
            SettingsCaption(text: "Running from Xcode — permission checks resolve against Xcode’s grants, not glance’s, so this reading is meaningless. Launch glance.app on its own to see the real state.")
        } else if needsInputMonitoring {
            inputMonitoringNotice()
        }

        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(text: "Behaviour")
            SettingsGroup {
                SettingsRowContent(title: "Retry on notch hover") {
                    GlanceToggle(isOn: $settings.retryOnHover)
                }
                SettingsGroupDivider()
                SettingsRowContent(title: "Auto retry once after failure") {
                    GlanceToggle(isOn: $settings.autoRetryOnce)
                }
                SettingsGroupDivider()
                SettingsRowContent(title: "Haptic feedback") {
                    GlanceToggle(isOn: $settings.hapticFeedbackEnabled)
                }
                SettingsGroupDivider()
                SettingsSteppedSliderRowContent(
                    title: "Face detection duration",
                    valueLabel: "\(settings.faceDetectionSeconds)s",
                    index: Binding(
                        get: { Double(settings.faceDetectionSeconds - GlanceSettings.faceDetectionRange.lowerBound) },
                        set: { settings.faceDetectionSeconds = GlanceSettings.faceDetectionRange.lowerBound + Int($0.rounded()) }
                    ),
                    stopCount: GlanceSettings.faceDetectionRange.count
                )
            }
        }

        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(text: "Night")
            SettingsGroup {
                SettingsRowContent(title: "Light up the screen in the dark") {
                    GlanceToggle(isOn: $settings.nightBoostEnabled)
                }
            }
            SettingsCaption(text: "When the room is dark, Glance turns the top of the display into a warm light for the length of the scan, lets the camera slow to 15 fps for a longer exposure, and brightens frames before recognition. Your brightness comes back when the scan ends.")
        }

        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(text: "Animation")
            SettingsGroup {
                SettingsRowContent(title: "Show animation") {
                    GlanceToggle(isOn: $settings.showUnlockAnimation)
                }
                SettingsGroupDivider()
                UnlockAnimationPicker(
                    selection: $settings.unlockAnimationStyle,
                    isEnabled: settings.showUnlockAnimation
                )
            }
        }
    }

    /// Shown while "On space" is selected but Input Monitoring isn't granted.
    private func inputMonitoringNotice() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsCaption(text: "“On space” reads the keyboard directly to see the space key on the lock screen, which needs Accessibility — the same permission glance uses to type your password. Switch glance on under Privacy & Security → Accessibility, then quit and reopen glance.")
            Button("Open Accessibility settings") {
                // Covers the rare install with no Accessibility grant at all.
                SpaceKeyMonitor.requestInputMonitoringAccess()
                openSystemSettings(pane: "Privacy_Accessibility")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                    inputMonitoring = SpaceKeyMonitor.inputMonitoringAccess
                }
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(GlanceTheme.accent)
        }
    }

    private func openSystemSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func displayPicker() -> some View {
        SettingsRowContent(title: "Display on") {
            SettingsMenuPickerPill(label: displayLabel) {
                // Not "Main display": unpinned placement prefers a notched
                // screen, then the built-in one, rather than NSScreen.main.
                Button("Automatic") {
                    settings.preferredDisplayID = nil
                    settings.preferredDisplayName = nil
                }
                ForEach(screens.compactMap(NamedScreen.init), id: \.id) { screen in
                    Button(screen.name) {
                        settings.preferredDisplayID = screen.id
                        settings.preferredDisplayName = screen.name
                    }
                }
            }
        }
    }

    /// A connected screen with its stable ID already unwrapped, so the
    /// picker's `ForEach` doesn't need to filter/force-unwrap inline.
    private struct NamedScreen {
        let id: String
        let name: String

        init?(_ screen: NSScreen) {
            guard let id = screen.stableDisplayID else { return nil }
            self.id = id
            self.name = screen.localizedName
        }
    }

    private var displayLabel: String {
        guard let targetID = settings.preferredDisplayID else { return "Automatic" }
        if let connected = screens.first(where: { $0.matches(displayID: targetID) }) {
            return connected.localizedName
        }
        // Picked, but not currently connected — say so rather than showing
        // a bare ID or falling back to another display's name.
        guard let name = settings.preferredDisplayName else { return "Selected display (disconnected)" }
        return "\(name) (disconnected)"
    }
}
