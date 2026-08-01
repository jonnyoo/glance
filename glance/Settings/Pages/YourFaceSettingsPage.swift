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

    var body: some View {
        Group {
            if store.isLocked {
                lockedState
            } else if let identity {
                enrolledState(identity)
            } else {
                emptyState
            }
        }
        .onAppear { store.reloadIfUnlocked() }
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

    private var lockedState: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingsCaption(text: "Authenticate to view your enrolled face.")
            SettingsActionRow(
                title: "Session locked",
                buttonTitle: isUnlocking ? "Authenticating…" : "Unlock with Touch ID",
                isEnabled: !isUnlocking,
                action: unlock
            )
            if let sessionError {
                SettingsCaption(text: sessionError)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingsCaption(text: "You haven't enrolled your face yet.")
            SettingsActionRow(title: "Face enrollment", buttonTitle: "Set Up Face Recognition") {
                OnboardingController.startEnrollmentOnly()
            }
        }
    }

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
