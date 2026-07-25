//
//  ContentView.swift
//  glance
//

import SwiftUI

struct ContentView: View {
    /// Shared across tabs (not created per-tab) so `FaceUnlockCoordinator`
    /// calls into the exact same controller instance the Credentials tab
    /// shows status for — two independent `POCController`s would each spin
    /// up their own `LockMonitor` and observe the same signal redundantly.
    @State private var pocController = POCController()

    var body: some View {
        TabView {
            CredentialPOCView(controller: pocController)
                .tabItem { Text("Credentials") }
            FaceLabView()
                .tabItem { Text("Face Lab") }
            FaceUnlockView(pocController: pocController)
                .tabItem { Text("Face Unlock") }
        }
        .frame(minWidth: 560, minHeight: 700)
    }
}

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
        .frame(minWidth: 460, minHeight: 560)
        .onAppear {
            controller.refreshAccessibilityStatus()
            controller.refreshCredentialStatus()
        }
    }
}

#Preview {
    ContentView()
}
