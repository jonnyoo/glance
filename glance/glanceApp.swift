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

    /// Only way to reliably reopen a `Window` scene once its `NSWindow` has
    /// fully closed — see `AppDelegate.openSettingsWindowAction`'s doc
    /// comment for why the previous `NSApp.windows` walk couldn't do this.
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        Window("Glance Settings", id: "settings") {
            SettingsWindowView(environment: appDelegate.environment)
                // Captured once the window's content actually appears —
                // always before launch finishes, well before the user could
                // click the menu bar item — so the action is ready the
                // first time anything needs it.
                .onAppear {
                    appDelegate.openSettingsWindowAction = { openWindow(id: "settings") }
                }
        }
        // Deliberately no `.windowResizability(.contentSize)`: it kept
        // re-deriving the window size as (content + titlebar band), which
        // grew the window every time the titlebar band changed height — and
        // it now has a real, taller one (see WindowConfiguringView's
        // toolbar). Size is set once by WindowConfiguringView instead, and
        // the window is made non-resizable there, so nothing re-derives it.
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    /// Owns the long-lived controllers (POCController, FaceUnlockCoordinator,
    /// FaceLabController) so every Settings page — and now the menu bar
    /// item's session row — shares the exact same instances instead of each
    /// spinning up its own camera/lock-monitor — see AppEnvironment.swift.
    /// Lives here rather than as `glanceApp`'s `@State` so it's guaranteed
    /// to exist before `applicationDidFinishLaunching` builds the menu:
    /// `@NSApplicationDelegateAdaptor` constructs this delegate before the
    /// scene body ever runs, so reading `appDelegate.environment` from
    /// there is always safe, with no ordering race to reason about.
    let environment = AppEnvironment()

    /// Kept alive for the app's lifetime — an `NSStatusItem` is only
    /// retained by whoever holds a strong reference to it, so a local
    /// variable would vanish (and the icon with it) the moment
    /// `applicationDidFinishLaunching` returns.
    private var statusItem: NSStatusItem?
    /// The session lock/unlock row — held so `menuNeedsUpdate` can refresh
    /// its title/icon in place each time the menu opens, rather than
    /// tearing down and rebuilding the whole menu just for one row.
    private var sessionMenuItem: NSMenuItem?
    /// Bridges SwiftUI's `openWindow(\.settings)` environment action in
    /// from `glanceApp.body` — see that call site. This delegate is a plain
    /// `NSObject`, not a View, so it has no `@Environment` of its own;
    /// capturing the action as a closure once and calling it later is the
    /// standard way to reach a SwiftUI environment action from AppKit code.
    ///
    /// This exists because `NSApp.windows` stops containing the Settings
    /// window once it's fully closed (not just miniaturized/ordered out) —
    /// walking that array, which is what `revealSettingsWindow()` used to
    /// do exclusively, is a silent no-op in that state: no window to find,
    /// so nothing shows, though `NSApp.setActivationPolicy(.regular)`
    /// still ran, which is exactly the bug this fixed (Dock icon reappears,
    /// window doesn't). Only `openWindow(id:)` — SwiftUI's own API for its
    /// own scene — can reliably re-create a closed `Window` scene.
    var openSettingsWindowAction: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        // Custom mark (`Assets.xcassets/MenuBarIcon`), not an SF Symbol.
        // `isTemplate` lets AppKit recolor it for the menu bar's current
        // appearance/highlight state, same as every system menu bar icon —
        // the asset's own `template-rendering-intent` already declares
        // this, but setting it again here is cheap insurance against a
        // plain black-square render if that ever gets lost.
        let icon = NSImage(named: "MenuBarIcon")
        icon?.isTemplate = true
        // A single-scale vector asset reports its design size (181x174 —
        // the SVG's own `viewBox`) as `NSImage.size` with no scaling
        // metadata to shrink it, unlike raster @1x/@2x/@3x assets or an
        // `NSImage(systemSymbolName:)` glyph — left unset, this renders
        // the icon at roughly 10x the menu bar's actual height. 18pt tall
        // matches the standard macOS menu bar glyph size; width follows
        // the SVG's own ~1.04 aspect ratio rather than forcing a square.
        if let iconSize = icon?.size, iconSize.height > 0 {
            let menuBarHeight: CGFloat = 16
            icon?.size = NSSize(width: menuBarHeight * iconSize.width / iconSize.height, height: menuBarHeight)
        }
        item.button?.image = icon

        let menu = NSMenu()
        // Refreshes `sessionMenuItem` right before the menu displays — see
        // `menuNeedsUpdate` below.
        menu.delegate = self

        let sessionItem = NSMenuItem(title: "", action: #selector(toggleSession), keyEquivalent: "")
        sessionItem.target = self
        menu.addItem(sessionItem)
        sessionMenuItem = sessionItem

        let settingsItem = NSMenuItem(title: "Settings", action: #selector(openSettingsWindow), keyEquivalent: ",")
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gearshape.fill", accessibilityDescription: nil)
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quitItem.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)
        menu.addItem(quitItem)

        item.menu = menu
        statusItem = item

        updateSessionMenuItem()

        // `object: nil` (not a specific window reference) deliberately —
        // the Settings window may not exist yet at this point (SwiftUI
        // creates `Window` scene content lazily around launch), and this
        // still matches it by identity inside the handler below once it
        // does close.
        NotificationCenter.default.addObserver(
            self, selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification, object: nil
        )

        // Safe to call with the placeholder `SUPublicEDKey` still in
        // Info.plist — see `UpdaterController.start()`'s doc comment.
        environment.updater.start()
    }

    /// Hides the Dock icon once the Settings window closes and no other
    /// main window is left — `revealSettingsWindow()` brings it back. Only
    /// `canBecomeMain` windows count: this app can spawn other AppKit
    /// windows behind the scenes (e.g. the lock-screen notch overlay),
    /// which must never trigger this or the Dock icon would vanish while
    /// an unlock scan is actually in progress. Sparkle's update windows are
    /// also `canBecomeMain`, so this additionally backs off while one is
    /// showing — otherwise closing Settings mid-update would flip the Dock
    /// icon off while Sparkle's own window is still on screen.
    @objc private func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow, closingWindow.canBecomeMain else { return }
        guard !environment.updater.isPresentingUpdateUI else { return }
        let stillOpen = NSApp.windows.contains { $0 !== closingWindow && $0.canBecomeMain && $0.isVisible }
        guard !stillOpen else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// `NSMenuDelegate`: fires right before the menu opens, which is where
    /// the session row's title/icon get refreshed — simpler and cheaper
    /// than keeping an `NSMenuItem` (not a SwiftUI view) reactively bound
    /// to `POCController.isSessionUnlocked` for the whole time the app runs.
    func menuNeedsUpdate(_ menu: NSMenu) {
        updateSessionMenuItem()
    }

    private func updateSessionMenuItem() {
        guard let sessionMenuItem else { return }
        let isUnlocked = environment.pocController.isSessionUnlocked
        sessionMenuItem.title = isUnlocked ? "Session Unlocked" : "Session Locked"
        sessionMenuItem.image = NSImage(
            systemSymbolName: isUnlocked ? "lock.open.fill" : "lock.fill",
            accessibilityDescription: nil
        )
    }

    /// Toggles the credential session — the same Touch-ID-gated lock the
    /// Recognition/Password/Your Face settings pages sit behind. Locking is
    /// immediate; unlocking prompts Touch ID via `POCController
    /// .unlockSession()`, so this can't be a plain synchronous `@objc`
    /// action for that branch.
    @objc private func toggleSession() {
        if environment.pocController.isSessionUnlocked {
            environment.pocController.lockSession()
        } else {
            Task { await environment.pocController.unlockSession() }
        }
    }

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
            revealSettingsWindow()
        }
        return true
    }

    /// Same "bring the existing Settings window forward" behavior as
    /// clicking the Dock icon, invoked from the menu bar item instead —
    /// one path for "the user wants to see the window," not two to keep
    /// in sync.
    @objc private func openSettingsWindow() {
        revealSettingsWindow()
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Restores the Dock icon (`windowWillClose` is what hides it) before
    /// bringing the window forward — switching `.accessory` -> `.regular`
    /// after the window is already key can leave the Dock icon out of sync
    /// with an already-frontmost app, so the policy change goes first.
    private func revealSettingsWindow() {
        NSApp.setActivationPolicy(.regular)
        if let openSettingsWindowAction {
            openSettingsWindowAction()
        } else {
            // `body` hasn't run yet somehow (shouldn't happen in practice —
            // see `openSettingsWindowAction`'s doc comment) — falls back to
            // the old direct walk, which only works while a window instance
            // still technically exists (e.g. merely ordered out), not once
            // one has fully closed.
            for window in NSApp.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
        }
    }
}
