import SwiftUI
import AppKit

@main
struct IRLabApp: App {
    @NSApplicationDelegateAdaptor(IRLabDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("Glance IR Lab") {
            ScrollView {
                InfraredLabView()
                    .padding(20)
            }
            .frame(width: 620, height: 620)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class IRLabDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
