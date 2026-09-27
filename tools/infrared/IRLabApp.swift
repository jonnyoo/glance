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
            .frame(minWidth: 640, idealWidth: 680, minHeight: 700, idealHeight: 820)
        }
        .defaultSize(width: 680, height: 820)
        .windowResizability(.contentMinSize)
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
