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

    /// Three mutually exclusive states, not two — "no password stored" takes
    /// priority over lock state entirely. Without that, right after removal
    /// (which also destroys the session key, see `removePassword`) this
    /// would fall back to the ordinary "Session locked" prompt, offering to
    /// unlock a session that no longer protects anything — and even if the
    /// user unlocked a *fresh* bootstrap session afterward, `unlockedState`'s
    /// "Password encrypted" / "Remove password" rows would be actively
    /// wrong with nothing stored to encrypt or remove.
    private enum PageState: Equatable {
        case noPassword
        case locked
        case unlocked
    }

    private var pageState: PageState {
        guard pocController.hasStoredPassword else { return .noPassword }
        return isSessionUnlocked ? .unlocked : .locked
    }

    var body: some View {
        ZStack(alignment: .top) {
            noPasswordState
                .opacity(pageState == .noPassword ? 1 : 0)
                // Hidden from hit-testing *and* accessibility while faded
                // out, so an invisible copy can't be clicked or focused.
                .allowsHitTesting(pageState == .noPassword)
                .accessibilityHidden(pageState != .noPassword)

            lockedState
                .opacity(pageState == .locked ? 1 : 0)
                .allowsHitTesting(pageState == .locked)
                .accessibilityHidden(pageState != .locked)

            unlockedState
                .opacity(pageState == .unlocked ? 1 : 0)
                .allowsHitTesting(pageState == .unlocked)
                .accessibilityHidden(pageState != .unlocked)
        }
        .animation(SettingsMetrics.stateTransitionAnimation, value: pageState)
        .onAppear { pocController.refreshCredentialStatus() }
        // The onboarding password step runs in the notch, entirely outside
        // this window's view hierarchy — this view never disappears while
        // it's open, so nothing would otherwise prompt a re-check once it
        // closes. Without this, setting a password via "Set password" (or
        // changing one via "Change") would leave this page showing stale
        // state until the user happened to switch tabs and back. `.closed`
        // also fires after unrelated face-unlock scan cycles; re-running a
        // cheap, side-effect-free status read then is harmless.
        .onChange(of: NotchOverlayController.shared.phase) { _, newPhase in
            guard newPhase == .closed else { return }
            pocController.refreshCredentialStatus()
            FaceEnrollmentStore.shared.reloadIfUnlocked()
        }
    }

    // MARK: - No password stored

    private var noPasswordState: some View {
        centeredState(
            message: "Set up a password",
            buttonTitle: "Set password",
            caption: statusMessage,
            action: { OnboardingController.startPasswordOnly() }
        )
    }

    // MARK: - Locked

    private var lockedState: some View {
        centeredState(
            message: "Session locked",
            buttonTitle: isUnlocking ? "Authenticating…" : "Unlock session",
            isButtonEnabled: !isUnlocking,
            caption: sessionError,
            action: unlock
        )
    }

    /// Shared layout for the two centered, icon-led states — same chrome,
    /// different text/button/caption. `noPasswordState` and `lockedState`
    /// look identical apart from those three things by design (see
    /// `PageState`'s doc comment for why they're separate states at all).
    private func centeredState(
        message: String,
        buttonTitle: String,
        isButtonEnabled: Bool = true,
        caption: String?,
        action: @escaping () -> Void
    ) -> some View {
        VStack(spacing: SettingsMetrics.emptyStateSpacing) {
            Image(systemName: "lock.fill")
                .font(.system(size: SettingsMetrics.emptyStateIconSize, weight: .regular))
                .foregroundStyle(SettingsMetrics.textTertiary)

            Text(message)
                .font(SettingsMetrics.rowFont)
                .foregroundStyle(SettingsMetrics.textSecondary)

            SettingsPrimaryButton(title: buttonTitle, isEnabled: isButtonEnabled, action: action)

            if let caption {
                SettingsCaption(text: caption)
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

                SettingsRowContent(
                    title: "Remove password",
                ) {
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
    ///
    /// `statusMessage` is set here but rendered from `noPasswordState`, not
    /// `unlockedState` — this call is exactly what makes `pageState` leave
    /// `.unlocked` for `.noPassword` (no password remains), so a message
    /// left only on the view being faded out would flash and vanish with
    /// it before anyone could read it.
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
