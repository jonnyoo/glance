//
//  RecognitionSettingsPage.swift
//  glance
//
//  Gated behind the same Touch-ID session as Password/Your Face: match
//  threshold and minimum-face-size are recognition-tuning knobs, and
//  changing them while locked would be adjusting how face unlock behaves
//  without having proven you're allowed to touch it at all.
//

import SwiftUI

struct RecognitionSettingsPage: View {
    @Bindable var coordinator: FaceUnlockCoordinator
    let faceLabController: FaceLabController
    @Bindable var pocController: POCController
    @Bindable private var settings = GlanceSettings.shared

    @State private var isUnlocking = false
    @State private var sessionError: String?

    /// Read from `POCController` rather than a local `@State` copy — same
    /// reasoning as `PasswordSettingsPage`: the session can lock itself out
    /// from under this page (`SessionAutoLocker`, or the Password tab's
    /// "Remove password"), and a local copy wouldn't notice.
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
        // Password/name/enrollment flows run in the notch, entirely
        // outside this window — this page never disappears while one is
        // open, so nothing else would prompt a re-check once it closes.
        .onChange(of: NotchOverlayController.shared.phase) { _, newPhase in
            guard newPhase == .closed else { return }
            pocController.refreshCredentialStatus()
        }
    }

    // MARK: - Locked

    private var lockedState: some View {
        SettingsEmptyStateView(
            icon: "lock.fill",
            message: "Session locked",
            buttonTitle: isUnlocking ? "Authenticating…" : "Unlock session",
            isButtonEnabled: !isUnlocking,
            caption: sessionError,
            action: unlock
        )
    }

    // MARK: - Unlocked

    private var unlockedState: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingsSlider(
                title: "Match threshold",
                subtitle: "How similar a live face must be to your enrolled face to count as a match. Lower is more lenient, higher is stricter.",
                value: $coordinator.matchThreshold,
                range: -1...1
            )

            if let suggested = faceLabController.suggestedThreshold {
                SettingsActionRow(
                    title: "Face Lab suggests \(String(format: "%.2f", suggested))",
                    subtitle: "Based on calibration samples recorded in the Face Lab debug tab this session.",
                    buttonTitle: "Use This Value"
                ) {
                    coordinator.matchThreshold = suggested
                }
            }

            SettingsSlider(
                title: "Minimum face size",
                subtitle: "How large a face must appear in frame to be considered. Lower values also recognize faces farther from the camera, but make it easier for someone in the background to be picked up by mistake.",
                value: $settings.minimumFaceWidth,
                range: 0.05...0.6
            )
        }
    }

    // MARK: - Actions

    private func unlock() {
        isUnlocking = true
        sessionError = nil
        Task {
            await pocController.unlockSession()
            sessionError = pocController.sessionError
            isUnlocking = false
        }
    }
}
