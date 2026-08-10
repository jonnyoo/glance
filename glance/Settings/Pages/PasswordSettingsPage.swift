//
//  PasswordSettingsPage.swift
//  glance
//

import SwiftUI

struct PasswordSettingsPage: View {
    @State private var isSessionUnlocked = SecureCredentialManager.isSessionUnlocked
    @State private var isUnlocking = false
    @State private var sessionError: String?

    @State private var newPassword = ""
    @State private var statusMessage: String?
    @State private var isSaving = false

    @State private var showRemoveConfirmation = false

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            if !isSessionUnlocked {
                SettingsActionRow(
                    title: "Session locked",
                    buttonTitle: isUnlocking ? "Authenticating…" : "Unlock with Touch ID",
                    isEnabled: !isUnlocking,
                    action: unlock
                )
                if let sessionError {
                    SettingsCaption(text: sessionError)
                }
            } else {
                SettingsRow(title: "New password") {
                    SecureField("Enter password", text: $newPassword)
                        .textFieldStyle(.plain)
                        .foregroundStyle(SettingsMetrics.textPrimary)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 200)
                }

                SettingsActionRow(
                    title: "Save new password",
                    buttonTitle: isSaving ? "Saving…" : "Save",
                    isEnabled: !isSaving && !newPassword.isEmpty,
                    action: savePassword
                )

                SettingsActionRow(
                    title: "Remove stored password",
                    subtitle: "Also permanently deletes your enrolled face — both are protected by the same key.",
                    buttonTitle: "Remove",
                    isDestructive: true,
                    action: { showRemoveConfirmation = true }
                )
            }

            if let statusMessage {
                SettingsCaption(text: statusMessage)
            }
        }
        .confirmationDialog(
            "Remove your stored password?",
            isPresented: $showRemoveConfirmation,
            titleVisibility: .visible
        ) {
            Button("Remove Password & Face Enrollment", role: .destructive) {
                removePassword()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This deletes both your stored Mac password and your enrolled face — they're protected by the same encryption key and can't be removed separately. Face unlock and auto-unlock will stop working until you set both up again.")
        }
    }

    private func unlock() {
        isUnlocking = true
        sessionError = nil
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try SecureCredentialManager.unlockSession(reason: "Authenticate to change your stored password")
                }.value
                isSessionUnlocked = true
            } catch {
                sessionError = error.localizedDescription
            }
            isUnlocking = false
        }
    }

    private func savePassword() {
        let plaintext = newPassword
        newPassword = ""
        isSaving = true
        statusMessage = nil
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    guard var bytes = plaintext.data(using: .utf8) else {
                        throw SecureCredentialError.emptyPassword
                    }
                    defer { bytes.resetBytes(in: 0..<bytes.count) }
                    try SecureCredentialManager.savePassword(bytes)
                }.value
                statusMessage = "Password updated."
            } catch {
                statusMessage = "Couldn't save: \(error.localizedDescription)"
            }
            isSaving = false
        }
    }

    /// Face samples must be deleted *before* the password/session key —
    /// `deletePassword()` also clears the cached session key, and deleting
    /// the face store requires an unlocked session.
    private func removePassword() {
        do {
            try? FaceEnrollmentStore.shared.deleteAll()
            try SecureCredentialManager.deletePassword()
            isSessionUnlocked = SecureCredentialManager.isSessionUnlocked
            statusMessage = "Password and face enrollment removed."
        } catch {
            statusMessage = "Couldn't remove: \(error.localizedDescription)"
        }
    }
}
