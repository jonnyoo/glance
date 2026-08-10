//
//  YourFaceSettingsPage.swift
//  glance
//

import SwiftUI

struct YourFaceSettingsPage: View {
    let environment: AppEnvironment
    @Bindable private var store = FaceEnrollmentStore.shared

    @State private var sessionError: String?
    @State private var isUnlocking = false
    @State private var showDeleteConfirmation = false

    private var identity: FaceIdentity? {
        store.identities.first
    }

    /// Locked takes priority over enrollment status for a reason specific to
    /// this store, not just copied from Password's page: `FaceIdentity` data
    /// is encrypted under the session key (see `FaceEnrollmentStore
    /// .reloadIfUnlocked`), so whether anyone is enrolled is simply *unknown*
    /// until the session is unlocked — unlike a stored password, whose
    /// existence is a plain Keychain check needing no decryption at all.
    /// There is no way to show "not enrolled" before that.
    private enum PageStateKind: Equatable {
        case locked
        case notEnrolled
        case enrolled
    }

    private var stateKind: PageStateKind {
        if store.isLocked { return .locked }
        return identity == nil ? .notEnrolled : .enrolled
    }

    var body: some View {
        ZStack(alignment: .top) {
            lockedState
                .opacity(stateKind == .locked ? 1 : 0)
                .allowsHitTesting(stateKind == .locked)
                .accessibilityHidden(stateKind != .locked)

            notEnrolledState
                .opacity(stateKind == .notEnrolled ? 1 : 0)
                .allowsHitTesting(stateKind == .notEnrolled)
                .accessibilityHidden(stateKind != .notEnrolled)

            if let identity {
                enrolledState(identity)
                    .opacity(stateKind == .enrolled ? 1 : 0)
                    .allowsHitTesting(stateKind == .enrolled)
                    .accessibilityHidden(stateKind != .enrolled)
            }
        }
        .animation(SettingsMetrics.stateTransitionAnimation, value: stateKind)
        .onAppear { store.reloadIfUnlocked() }
        // The enrollment flow runs in the notch, entirely outside this
        // window's view hierarchy — this view never disappears while it's
        // open, so nothing else would prompt a re-check once it closes.
        // Without this, finishing "Set up FaceID" (or "Redo Face Enrollment")
        // would leave this page on its old state until the user happened to
        // switch tabs and back.
        .onChange(of: NotchOverlayController.shared.phase) { _, newPhase in
            guard newPhase == .closed else { return }
            store.reloadIfUnlocked()
        }
        .confirmationDialog(
            "Delete your enrolled face?",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                try? store.deleteAll()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Face unlock will stop working until you re-enroll.")
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

    // MARK: - Not enrolled

    private var notEnrolledState: some View {
        SettingsEmptyStateView(
            icon: "faceid",
            message: "Face enrollment",
            buttonTitle: "Set up FaceID",
            action: { OnboardingController.startEnrollmentOnly() }
        )
    }

    // MARK: - Enrolled

    private func enrolledState(_ identity: FaceIdentity) -> some View {
        let posesCaptured = Set(identity.samples.compactMap(\.pose)).count
        let embedder = environment.faceLabController.pipeline.embedder
        let stale = identity.isStale(comparedTo: embedder)

        return VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingsRow(title: "Enrolled", subtitle: "\(posesCaptured) poses captured, \(identity.samples.count) samples") {
                Circle()
                    .fill(stale ? GlanceTheme.statusDenied : GlanceTheme.statusGranted)
                    .frame(width: 10, height: 10)
            }

            if stale {
                SettingsCaption(text: "Your enrollment was captured with a different recognition model and needs to be redone before face unlock will work.")
            }

            SettingsRow(title: "Enrolled on") {
                Text(identity.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 13))
                    .foregroundStyle(SettingsMetrics.textSecondary)
            }

            SettingsActionRow(title: "Redo Face Enrollment", buttonTitle: "Start") {
                OnboardingController.startEnrollmentOnly()
            }

            SettingsActionRow(
                title: "Delete Enrollment",
                subtitle: "Removes your enrolled face.",
                buttonTitle: "Delete",
                isDestructive: true
            ) {
                showDeleteConfirmation = true
            }
        }
    }

    // MARK: - Actions

    private func unlock() {
        isUnlocking = true
        sessionError = nil
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try SecureCredentialManager.unlockSession(reason: "Authenticate to view your enrolled face")
                }.value
                store.reloadIfUnlocked()
            } catch {
                sessionError = error.localizedDescription
            }
            isUnlocking = false
        }
    }
}
