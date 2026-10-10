//
//  PasswordSettingsPage.swift
//  glance
//

import SwiftUI

struct PasswordSettingsPage: View {
    @Bindable var pocController: POCController
    @Bindable private var settings = GlanceSettings.shared

    @State private var isChangingPassword = false
    @State private var inlinePassword = ""
    @State private var isTestingUnlock = false
    @State private var testCountdown = 0
    @State private var statusMessage: String?
    @State private var isSaving = false

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            // MARK: - Accessibility Warning Banner
            if !pocController.accessibilityGranted {
                accessibilityBanner
            }

            // MARK: - Password Configuration Card
            SettingsGroup {
                if pocController.hasStoredPassword && !isChangingPassword {
                    // Password already stored
                    SettingsRowContent(
                        title: "Mac Login Password",
                        info: "Hardware-encrypted in Apple Keychain on this device. Used exclusively to unlock your Mac when your face is recognized."
                    ) {
                        HStack(spacing: 6) {
                            Image(systemName: "checkmark.shield.fill")
                                .foregroundStyle(Color.green)
                            Text("Configured")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    SettingsGroupDivider()

                    SettingsRowContent(title: "Change password") {
                        SettingsPrimaryButton(title: "Change", compact: true) {
                            inlinePassword = ""
                            isChangingPassword = true
                        }
                    }

                    SettingsGroupDivider()

                    SettingsRowContent(
                        title: "Test auto-unlock",
                        info: "Tests typing the password into whatever is focused."
                    ) {
                        SettingsPrimaryButton(
                            title: isTestingUnlock ? "Testing (\(testCountdown)s)…" : "Test Now",
                            isEnabled: !isTestingUnlock,
                            compact: true
                        ) {
                            runUnlockTest()
                        }
                    }

                    SettingsGroupDivider()

                    SettingsRowContent(title: "Remove password") {
                        HoldToConfirmButton(title: "Remove", action: removePassword)
                    }
                } else {
                    // Setup / Change password inline
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Image(systemName: "key.fill")
                                .foregroundStyle(GlanceTheme.accent)
                            Text(isChangingPassword ? "Change Mac Password" : "Set Up Mac Password")
                                .font(SettingsMetrics.rowFont)
                                .foregroundStyle(SettingsMetrics.textPrimary)
                            Spacer()
                            if isChangingPassword {
                                Button("Cancel") {
                                    isChangingPassword = false
                                    inlinePassword = ""
                                }
                                .buttonStyle(.plain)
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            }
                        }

                        Text("Enter your Mac user password. It will be encrypted locally using Apple's Secure Enclave and typed automatically when your face is verified.")
                            .font(.system(size: 11))
                            .foregroundStyle(SettingsMetrics.textSecondary)

                        HStack(spacing: 8) {
                            SecureField("Enter your Mac password", text: $inlinePassword)
                                .textFieldStyle(.roundedBorder)

                            SettingsPrimaryButton(
                                title: isSaving ? "Saving…" : "Save Password",
                                isEnabled: !inlinePassword.isEmpty && !isSaving,
                                compact: true
                            ) {
                                saveInlinePassword()
                            }
                        }
                    }
                    .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
                    .padding(.vertical, 12)
                }
            }

            // MARK: - Auto-lock Settings
            if pocController.hasStoredPassword {
                VStack(alignment: .leading, spacing: 8) {
                    SettingsSectionTitle(text: "Session Security")
                    SettingsGroup {
                        SettingsSteppedSliderRowContent(
                            title: "Auto-lock session",
                            valueLabel: settings.autoLockInterval.title,
                            index: Binding(
                                get: { settings.autoLockInterval.sliderIndex },
                                set: { settings.autoLockInterval = .from(sliderIndex: $0) }
                            ),
                            stopCount: AutoLockInterval.allCases.count
                        )
                    }
                }
            }

            // MARK: - Status Messages
            if let status = statusMessage ?? (pocController.statusMessage == "Idle" ? nil : pocController.statusMessage) {
                SettingsCaption(text: status)
            }
        }
        .onAppear {
            pocController.refreshCredentialStatus()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            pocController.refreshCredentialStatus()
        }
    }

    // MARK: - Accessibility Banner

    private var accessibilityBanner: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 20))
                .foregroundStyle(Color.orange)

            VStack(alignment: .leading, spacing: 4) {
                Text("Accessibility Permission Needed")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Text("macOS requires Accessibility permission for iFace so it can enter your password on the lock screen. If already checked in System Settings, try toggling it OFF and ON, or click Restart iFace below.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button(action: { pocController.openAccessibilitySettings() }) {
                        HStack(spacing: 4) {
                            Image(systemName: "gearshape.fill")
                            Text("Open System Settings")
                        }
                        .font(.system(size: 11, weight: .medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)

                    Button("Check Again") {
                        pocController.refreshCredentialStatus()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    Button("Restart iFace") {
                        relaunchApp()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .padding(.top, 4)
            }
            Spacer()
        }
        .padding(12)
        .background(Color.orange.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.orange.opacity(0.3), lineWidth: 1)
        )
    }

    // MARK: - Actions

    private func saveInlinePassword() {
        guard !inlinePassword.isEmpty else { return }
        isSaving = true
        pocController.passwordInput = inlinePassword
        Task {
            await pocController.savePassword()
            isSaving = false
            inlinePassword = ""
            isChangingPassword = false
            statusMessage = pocController.statusMessage
            FaceEnrollmentStore.shared.reloadIfUnlocked()
        }
    }

    private func runUnlockTest() {
        isTestingUnlock = true
        testCountdown = 3
        statusMessage = "Focus on a text field within 3 seconds to see your password injected…"

        Task {
            for i in stride(from: 3, through: 1, by: -1) {
                testCountdown = i
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            testCountdown = 0
            await pocController.injectStoredPassword(requireAuthoritativeLock: false)
            isTestingUnlock = false
            statusMessage = pocController.statusMessage
        }
    }

    private func removePassword() {
        do {
            FaceEnrollmentStore.shared.deleteAll()
            try SecureCredentialManager.deletePassword()
            pocController.refreshCredentialStatus()
            statusMessage = "Password and face enrollment removed."
        } catch {
            statusMessage = "Couldn't remove: \(error.localizedDescription)"
        }
    }

    private func relaunchApp() {
        let appURL = Bundle.main.bundleURL
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { _, _ in
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }
}
