//
//  ContentView.swift
//  glance
//

import SwiftUI

struct ContentView: View {
    @State private var controller = POCController()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Presence POC — Lock Screen Injection Test")
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

            GroupBox("Test Injection") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Test string", text: $controller.testString)
                        .textFieldStyle(.roundedBorder)

                    Toggle("Auto-inject once when screen locks", isOn: $controller.autoInjectOnLock)

                    Button("Inject Now") {
                        Task { await controller.injectTestString() }
                    }
                    .keyboardShortcut(.return, modifiers: [.command])
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
        .frame(minWidth: 420, minHeight: 380)
        .onAppear {
            controller.refreshAccessibilityStatus()
        }
    }
}

#Preview {
    ContentView()
}
