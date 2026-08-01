//
//  ContentView.swift
//  glance
//

import SwiftUI

/// The debug console this used to be a standalone window for now lives
/// under the Settings window's DEBUG sidebar category (see
/// SettingsWindowView) — this file now only hosts the Credentials tab's
/// content view, unchanged.
struct CredentialPOCView: View {
    @Bindable var controller: POCController

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Presence POC — Secure Credential Storage")
                .font(.headline)

            GroupBox("Accessibility") {
                HStack {
                    Circle()
                        .fill(controller.accessibilityGranted ? .green : .red)
                        .frame(width: 10, height: 10)
                    Text(controller.accessibilityGranted ? "Granted" : "Not granted")
                    Spacer()
                    Button("Grant…") {
                        controller.requestAccessibility()
                    }
                    Button("Refresh") {
                        controller.refreshAccessibilityStatus()
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox("Lock State") {
                HStack {
                    Circle()
                        .fill(controller.lockMonitor.isScreenLocked ? .orange : .green)
                        .frame(width: 10, height: 10)
                    Text(controller.lockMonitor.isScreenLocked ? "Locked (notification)" : "Unlocked (notification)")
                    Spacer()
                    Text(LockMonitor.isScreenActuallyLocked() ? "CGSession: locked" : "CGSession: unlocked")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            GroupBox("Credential Setup") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Circle()
                            .fill(controller.isSessionUnlocked ? .green : .gray)
                            .frame(width: 10, height: 10)
                        Text(controller.isSessionUnlocked ? "Session unlocked" : "Session locked")
                        Spacer()
                        Button(controller.isSessionUnlocked ? "Lock Session" : "Unlock with Touch ID") {
                            if controller.isSessionUnlocked {
                                controller.lockSession()
                            } else {
                                Task { await controller.unlockSession() }
                            }
                        }
                    }

                    if let sessionError = controller.sessionError {
                        Text(sessionError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Divider()

                    SecureField("Mac password", text: $controller.passwordInput)
                        .textFieldStyle(.roundedBorder)
                        .disabled(!controller.isSessionUnlocked)

                    Button("Save Password") {
                        Task { await controller.savePassword() }
                    }
                    .disabled(!controller.isSessionUnlocked || controller.passwordInput.isEmpty)

                    Text(controller.hasStoredPassword ? "A password is stored (encrypted)." : "No password stored yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            GroupBox("Injection") {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Auto-inject once when screen locks", isOn: $controller.autoInjectOnLock)

                    Button("Inject Stored Password") {
                        Task { await controller.injectStoredPassword() }
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
                    .disabled(!controller.hasStoredPassword || !controller.isSessionUnlocked)
                }
                .padding(.vertical, 4)
            }

            Text(controller.statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer()
        }
        .padding(20)
        .onAppear {
            controller.refreshAccessibilityStatus()
            controller.refreshCredentialStatus()
        }
    }
}
