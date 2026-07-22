//
//  MenuBarContent.swift
//  FaceUnlock
//
//  The dropdown shown when the user clicks the menu-bar icon.
//

import SwiftUI
import AppKit

struct MenuBarContent: View {
    @Bindable var controller: AppController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Status row 1: lock state
        if controller.lockMonitor.isScreenLocked {
            Text("🔒  Screen is locked")
        } else {
            Text("🔓  Screen is unlocked")
        }

        // Status row 2: setup readiness
        if controller.canAttemptUnlock {
            Text("✓  Ready to unlock")
        } else {
            Text("⚠️  " + controller.unlockReadinessHint)
        }

        // Session-lock row (only visible when a password is stored but the session is locked)
        if controller.hasStoredPassword && !controller.isSessionUnlocked {
            Text("🔐  Session locked — Touch ID required")
        }

        Divider()

        // If session is locked, offer a quick way to unwrap it.
        if controller.hasStoredPassword && !controller.isSessionUnlocked {
            Button("Unlock Session (Touch ID)…") {
                Task { await controller.unlockSession() }
            }
            Divider()
        }

        // Quick toggle for auto-unlock
        Toggle("Auto-unlock on display wake", isOn: $controller.autoUnlockEnabled)
            .disabled(!controller.canAttemptUnlock)

        Divider()

        // Open the settings window
        Button("Open Settings…") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Menu("Icon Placement") {
            Toggle("Show in Dock", isOn: $controller.showInDock)
            Toggle("Show in Menu Bar", isOn: $controller.showInMenuBar)
        }

        Divider()

        Button("Quit FaceUnlock") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}

