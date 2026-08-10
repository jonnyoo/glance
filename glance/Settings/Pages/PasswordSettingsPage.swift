//
//  PasswordSettingsPage.swift
//  glance
//

import SwiftUI

struct PasswordSettingsPage: View {
    @Bindable var pocController: POCController
    @Bindable private var settings = GlanceSettings.shared

    @State private var isUnlocking = false
    @State private var sessionError: String?
    @State private var statusMessage: String?

    /// Read from `POCController` rather than a local `@State` copy: the
    /// session can also be locked from outside this view (by
    /// `SessionAutoLocker` when the idle limit elapses), and a local copy
    /// would keep rendering the unlocked state for a session that's gone.
    private var isSessionUnlocked: Bool { pocController.isSessionUnlocked }

    var body: some View {
        ZStack(alignment: .top) {
            lockedState
                .opacity(isSessionUnlocked ? 0 : 1)
                // Hidden from hit-testing *and* accessibility while faded
                // out, so the invisible copy can't be clicked or focused.
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
        VStack(spacing: SettingsMetrics.emptyStateSpacing) {
            Image(systemName: "lock.fill")
                .font(.system(size: SettingsMetrics.emptyStateIconSize, weight: .regular))
                .foregroundStyle(SettingsMetrics.textTertiary)

            Text("Session locked")
                .font(SettingsMetrics.rowFont)
                .foregroundStyle(SettingsMetrics.textSecondary)

            SettingsPrimaryButton(
                title: isUnlocking ? "Authenticating…" : "Unlock session",
                isEnabled: !isUnlocking,
                action: unlock
            )

            if let sessionError {
                SettingsCaption(text: sessionError)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: SettingsMetrics.emptyStateMinHeight)
    }

    // MARK: - Unlocked

    private var unlockedState: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingsGroup {
                SettingsRowContent(title: "Password encrypted") {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsMetrics.textSecondary)
                }

                SettingsGroupDivider()

                SettingsSteppedSliderRowContent(
                    title: "Auto lock session",
                    valueLabel: settings.autoLockInterval.title,
                    index: Binding(
                        get: { settings.autoLockInterval.sliderIndex },
                        set: { settings.autoLockInterval = .from(sliderIndex: $0) }
                    ),
                    stopCount: AutoLockInterval.allCases.count
                )

                SettingsGroupDivider()

                SettingsRowContent(title: "Change password") {
                    SettingsPrimaryButton(title: "Change", compact: true) {
                        OnboardingController.startPasswordOnly()
                    }
                }

                SettingsGroupDivider()

                SettingsRowContent(title: "Remove password") {
                    HoldToConfirmButton(title: "Remove", action: removePassword)
                }
            }

            if let statusMessage {
                SettingsCaption(text: statusMessage)
            }
        }
    }

    // MARK: - Actions

    private func unlock() {
        isUnlocking = true
        sessionError = nil
        Task {
            await pocController.unlockSession()
            sessionError = pocController.sessionError
            // The face store is encrypted under the same session key, so it
            // can only be read once that key exists — without this the Your
            // Face page stays "locked" until something else reloads it.
            FaceEnrollmentStore.shared.reloadIfUnlocked()
            isUnlocking = false
        }
    }

    /// Face samples must be deleted *before* the password/session key —
    /// `deletePassword()` also clears the cached session key, and deleting
    /// the face store requires an unlocked session.
    private func removePassword() {
        do {
            try? FaceEnrollmentStore.shared.deleteAll()
            try SecureCredentialManager.deletePassword()
            pocController.refreshCredentialStatus()
            statusMessage = "Password and face enrollment removed."
        } catch {
            statusMessage = "Couldn't remove: \(error.localizedDescription)"
        }
    }
}
