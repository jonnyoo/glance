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
    /// Refreshed on `didChangeScreenParametersNotification` (attached below)
    /// so the picker's menu reflects a display being connected/disconnected
    /// while Settings is open, rather than only whatever was plugged in
    /// when the page first appeared.
    @State private var screens: [NSScreen] = NSScreen.screens
    /// Whether "On space" can actually fire — refreshed when the app
    /// regains focus, so granting the permission in System Settings and
    /// switching back clears the prompt below without a relaunch.
    @State private var inputMonitoring = SpaceKeyMonitor.inputMonitoringAccess

    /// True once the user has picked "On space" but glance can't read the
    /// keyboard — the trigger is selected and persisted but can't fire yet.
    /// Normally false, since Accessibility (which glance needs regardless)
    /// already satisfies the check — see `SpaceKeyMonitor`'s file header.
    private var needsInputMonitoring: Bool {
        settings.unlockTriggers.contains(.onSpace) && inputMonitoring != .granted
    }

    /// Dev-only: under Xcode the reading above is Xcode's permission rather
    /// than glance's, so neither the notice nor its absence means anything.
    /// Self-gating — a normally launched build is never in this state. See
    /// `SpaceKeyMonitor.isLaunchedByXcode`.
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
            // Just switched "On space" on and can't fire yet → fire the
            // system prompt. Only on the transition into selection, so
            // toggling the other tiles never re-prompts.
            SpaceKeyMonitor.log.info("unlockTriggers changed: old=\(String(describing: oldValue), privacy: .public) new=\(String(describing: newValue), privacy: .public) state=\(String(describing: inputMonitoring), privacy: .public)")
            if newValue.contains(.onSpace), !oldValue.contains(.onSpace), inputMonitoring != .granted {
                SpaceKeyMonitor.requestInputMonitoringAccess()
                // Requesting writes a record (initially "off"), which flips
                // the state from `notDetermined` to `denied` — but tccd does
                // that just after the call returns, so re-read on the next
                // beat rather than inline.
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

    /// Shown while "On space" is selected but Input Monitoring isn't
    /// granted. The wording splits on the actual TCC state, because the two
    /// cases need different things from the user: `notDetermined` can still
    /// be prompted, `denied` cannot — no API can re-prompt once a decision
    /// is on record, so that one is a System Settings trip.
    private func inputMonitoringNotice() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsCaption(text: "“On space” reads the keyboard directly to see the space key on the lock screen, which needs Accessibility — the same permission glance uses to type your password. Switch glance on under Privacy & Security → Accessibility, then quit and reopen glance.")
            Button("Open Accessibility settings") {
                // Requesting HID access first covers the rare install that has
                // no Accessibility grant at all; where Accessibility is the
                // real gate, the deep link is what matters.
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
