//
//  FaceUnlockApp.swift
//  FaceUnlock
//
//  Created by Harsh on 25/06/26.
//

import SwiftUI
import AppKit

@main
struct FaceUnlockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var controller = AppController()

    var body: some Scene {
        // Settings window — reopenable by id from the menu bar.
        Window("FaceUnlock", id: "main") {
            ContentView(controller: controller)
        }
        .defaultSize(width: 530, height: 560)
        .windowResizability(.contentSize)

        // Status-bar icon — visibility controlled by user via `controller.showInMenuBar`.
        // Dock visibility is independently controlled via `NSApp.setActivationPolicy`.
        MenuBarExtra(
            "FaceUnlock",
            systemImage: "lock.fill",
            isInserted: Bindable(controller).showInMenuBar
        ) {
            MenuBarContent(controller: controller)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Keep the app process alive when the user closes the last window so the
    /// background auto-unlock trigger keeps firing.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// Reopen the main window when the user clicks the dock icon and no windows are open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }
}
