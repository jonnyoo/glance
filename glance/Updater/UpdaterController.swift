//
//  UpdaterController.swift
//  glance
//
//  Thin wrapper around Sparkle's `SPUStandardUpdaterController` (see RELEASING.md for the release process this depends on).
//  Split into two types because Sparkle's `@objc` delegate protocols need an `NSObject` conformer, which doesn't mix with
//  `@Observable`: `UpdaterController` is what the app touches; `UpdatePresentationDelegate` only relays Sparkle's show/hide callbacks.
//

import AppKit
import Observation
import Sparkle

@Observable
@MainActor
final class UpdaterController {
    private let controller: SPUStandardUpdaterController
    private let presentationDelegate = UpdatePresentationDelegate()

    /// Mirrors `SPUUpdater.canCheckForUpdates` (KVO-only on Sparkle's side, hence the manual observation below).
    private(set) var canCheckForUpdates = false
    private var canCheckForUpdatesObservation: NSKeyValueObservation?

    /// Forwards straight to Sparkle rather than keeping a second stored copy — Sparkle already persists this itself under the
    /// same `UserDefaults` suite `GlanceSettings` uses.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// True while Sparkle is showing anything, so `AppDelegate.windowWillClose` doesn't drop the Dock icon to `.accessory` mid-update.
    var isPresentingUpdateUI: Bool { presentationDelegate.isPresentingUpdateUI }

    init() {
        // `startingUpdater: false` — `start()` is called explicitly from `AppDelegate.applicationDidFinishLaunching` instead,
        // matching how the rest of `AppEnvironment`'s controllers are wired.
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: presentationDelegate
        )

        // Bridges KVO (not Observation-compatible) to the `@Observable` stored property SwiftUI tracks. Hopped through
        // `Task { @MainActor in }` since the KVO closure itself carries no actor isolation the compiler can see.
        canCheckForUpdatesObservation = controller.updater.observe(
            \.canCheckForUpdates, options: [.initial, .new]
        ) { updater, _ in
            // `[weak self]` captured on the Task's closure, not the outer KVO one — Swift 6 flags the latter as unsafe.
            let value = updater.canCheckForUpdates
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = value
            }
        }
    }

    /// Safe to call even with a placeholder `SUPublicEDKey` — `SPUStandardUpdaterController` logs and alerts on a misconfigured
    /// Sparkle setup itself rather than throwing.
    func start() {
        controller.startUpdater()
    }

    /// User-initiated "Check for Updates" — shows Sparkle's standard progress UI.
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// Receives Sparkle's show/hide callbacks to (a) bring the app forward when it's currently `.accessory`/windowless, and
/// (b) expose `isPresentingUpdateUI`. Only the three methods needed here are implemented; the rest of the protocol is optional.
@MainActor
private final class UpdatePresentationDelegate: NSObject, SPUStandardUserDriverDelegate {
    private(set) var isPresentingUpdateUI = false

    /// Fires before any modal alert, including the plain "You're up to date" sheet from a manual check.
    func standardUserDriverWillShowModalAlert() {
        beginPresenting()
    }

    /// Fires before Sparkle shows an actual found-update window, covering the real update path once releases exist.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        beginPresenting()
    }

    /// Fires for every way an update session can end (dismissed, skipped, errored, installed) — the one place to clear the flag.
    func standardUserDriverWillFinishUpdateSession() {
        isPresentingUpdateUI = false
    }

    private func beginPresenting() {
        isPresentingUpdateUI = true
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
