//
//  glanceApp.swift
//  glance
//
//  Created by Jonathan Zhou on 2026-07-21.
//

import SwiftUI

@main
struct glanceApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// Owns the long-lived controllers (POCController, FaceUnlockCoordinator,
    /// FaceLabController) so every Settings page shares the same instances
    /// instead of each spinning up its own camera/lock-monitor — see
    /// AppEnvironment.swift.
    @State private var environment = AppEnvironment()

    var body: some Scene {
        Window("Glance Settings", id: "settings") {
            SettingsWindowView(environment: environment)
        }
        // Deliberately no `.windowResizability(.contentSize)`: it kept
        // re-deriving the window size as (content + titlebar band), which is
        // what left the traffic lights stranded above the panel. Size is set
        // once by WindowConfiguringView instead, and the window is made
        // non-resizable there, so nothing needs to re-derive it.
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Keep the process alive after the window closes, so it can still react
    /// to the screen locking (e.g. for face unlock) while no window is visible.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    /// The app deliberately survives window close (above), which otherwise
    /// leaves no way to get the Settings window back for the rest of the
    /// session — this brings it back when the Dock icon is clicked.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }
        return true
    }
}
