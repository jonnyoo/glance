//
//  GeneralSettingsPage.swift
//  glance
//

import SwiftUI

struct GeneralSettingsPage: View {
    @Bindable var coordinator: FaceUnlockCoordinator
    @Bindable private var settings = GlanceSettings.shared

    @State private var launchAtLoginEnabled = LaunchAtLogin.isEnabled
    @State private var launchAtLoginError: String?
    /// Refreshed on `didChangeScreenParametersNotification` (attached below)
    /// so the picker's menu reflects a display being connected/disconnected
    /// while Settings is open, rather than only whatever was plugged in
    /// when the page first appeared.
    @State private var screens: [NSScreen] = NSScreen.screens

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
        if let launchAtLoginError {
            SettingsCaption(text: launchAtLoginError)
        }

        VStack(alignment: .leading, spacing: 8) {
            SettingsSectionTitle(text: "Behaviour")
            SettingsGroup {
                SettingsRowContent(title: "Retry FaceID on Hover") {
                    GlanceToggle(isOn: $settings.retryOnHover)
                }
                SettingsGroupDivider()
                SettingsRowContent(title: "Auto retry FaceID once") {
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

    /// Same Menu-in-a-capsule pattern as `CameraSettingsPage.cameraPicker` —
    /// "Main display" (nil) plus one entry per currently connected screen.
    /// Picking a specific screen also stashes its name
    /// (`GlanceSettings.preferredDisplayName`), purely so the row can still
    /// show something recognizable if that display later disconnects.
    private func displayPicker() -> some View {
        SettingsRowContent(title: "Display on") {
            ZStack {
                Capsule()
                    .fill(SettingsMetrics.pickerPillFill)

                Menu {
                    Button("Main display") {
                        settings.preferredDisplayID = nil
                        settings.preferredDisplayName = nil
                    }
                    ForEach(screens.compactMap(NamedScreen.init), id: \.id) { screen in
                        Button(screen.name) {
                            settings.preferredDisplayID = screen.id
                            settings.preferredDisplayName = screen.name
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(displayLabel)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(SettingsMetrics.textPrimary)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(SettingsMetrics.textSecondary)
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Capsule())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                // Window-level accent tint otherwise paints the menu label blue.
                .tint(SettingsMetrics.textPrimary)
            }
            .frame(width: 160, height: 28)
            .overlay {
                Capsule()
                    .strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
            }
        }
    }

    /// A connected screen with its stable ID already unwrapped, so the
    /// picker's `ForEach` doesn't need to filter/force-unwrap inline.
    /// `stableDisplayID` only fails for a screen AppKit can't report an
    /// `NSScreenNumber` for, which doesn't happen in practice.
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
        guard let targetID = settings.preferredDisplayID else { return "Main display" }
        if let connected = screens.first(where: { $0.stableDisplayID == targetID }) {
            return connected.localizedName
        }
        // Picked, but not currently connected — Face Unlock is correctly
        // not running anywhere right now (see
        // `FaceUnlockCoordinator.evaluateTrigger()`); say so rather than
        // showing a bare ID or silently falling back to another display's name.
        guard let name = settings.preferredDisplayName else { return "Selected display (disconnected)" }
        return "\(name) (disconnected)"
    }
}
