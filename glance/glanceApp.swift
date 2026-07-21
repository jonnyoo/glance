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

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Keep the process alive after the window closes, so it can still react
    /// to the screen locking (e.g. for the auto-inject test) while no window
    /// is visible.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
}
