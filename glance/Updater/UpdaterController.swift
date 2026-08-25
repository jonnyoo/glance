//
//  UpdaterController.swift
//  glance
//
//  Thin wrapper around Sparkle's `SPUStandardUpdaterController` — the
//  auto-update mechanism for glance, which ships outside the Mac App Store
//  (see RELEASING.md at the repo root for the full release process, feed
//  URL, and signing-key setup this depends on).
//
//  Split into two types because Sparkle's delegate protocols are `@objc`
//  and need an `NSObject`-backed conformer, which doesn't mix with the
//  `@Observable` macro:
//
//  - `UpdaterController` is what the rest of the app touches — About
//    settings binds to `canCheckForUpdates` / `automaticallyChecksForUpdates`
//    and calls `checkForUpdates()`; `AppDelegate` calls `start()` once at
//    launch and reads `isPresentingUpdateUI`.
//  - `UpdatePresentationDelegate` only exists to receive Sparkle's
//    show/hide callbacks and is not touched anywhere else.
//

import AppKit
import Observation
import Sparkle

@Observable
@MainActor
final class UpdaterController {
    private let controller: SPUStandardUpdaterController
    private let presentationDelegate = UpdatePresentationDelegate()

    /// Mirrors `SPUUpdater.canCheckForUpdates` (KVO-only on Sparkle's side,
    /// hence the manual observation below) — false while a check or
    /// install is already in flight, or before `start()` has run. Drives
    /// the About page's Check button `isEnabled`, replacing that row's old
    /// hardcoded `isEnabled: false`.
    private(set) var canCheckForUpdates = false
    private var canCheckForUpdatesObservation: NSKeyValueObservation?

    /// Forwards straight to Sparkle rather than keeping a second stored
    /// copy — Sparkle already persists this itself (`SUEnableAutomaticChecks`
    /// in the same `UserDefaults` suite the rest of `GlanceSettings` uses),
    /// so mirroring it locally would just be two sources of truth for one
    /// on-disk preference. This is also why `GlanceSettings
    /// .autoCheckForUpdates` was deleted rather than kept alongside it.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    /// True from the moment Sparkle is about to show anything — a modal
    /// alert (including "you're up to date") or the found-update window —
    /// until that update session ends. `AppDelegate.windowWillClose` checks
    /// this so the Dock icon doesn't drop back to `.accessory` mid-update
    /// just because the Settings window happened to be closed at the time.
    var isPresentingUpdateUI: Bool { presentationDelegate.isPresentingUpdateUI }

    init() {
        // `startingUpdater: false` — `start()` below is called explicitly
        // from `AppDelegate.applicationDidFinishLaunching` instead, so
        // launch order stays obvious and singular (one place that starts
        // things), matching how the rest of `AppEnvironment`'s controllers
        // are wired rather than started implicitly on init.
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: nil,
            userDriverDelegate: presentationDelegate
        )

        // `canCheckForUpdates` is KVO-only, not Observation-compatible, so
        // this is the bridge: every KVO change re-assigns the `@Observable`
        // stored property above, which is what SwiftUI actually tracks.
        // Hopped through `Task { @MainActor in }` rather than assigned
        // directly — the KVO closure itself is a plain, non-isolated
        // closure type from Foundation, so nothing guarantees the compiler
        // sees it as already running on the main actor even though Sparkle
        // only ever changes this property there in practice.
        canCheckForUpdatesObservation = controller.updater.observe(
            \.canCheckForUpdates, options: [.initial, .new]
        ) { updater, _ in
            // `[weak self]` captured on the `Task`'s own closure, not the
            // outer KVO one — capturing it there instead (the more obvious
            // way to write this) is what Swift 6 flags as a weak var
            // captured in concurrently-executing code, since the outer
            // closure itself carries no actor isolation of its own.
            let value = updater.canCheckForUpdates
            Task { @MainActor [weak self] in
                self?.canCheckForUpdates = value
            }
        }
    }

    /// Starts the updater — safe to call even with a placeholder
    /// `SUPublicEDKey` (see `Info.plist`): `SPUStandardUpdaterController`
    /// handles a misconfigured Sparkle setup itself, logging the problem
    /// and showing the user a delayed alert rather than throwing. There is
    /// deliberately no error-handling wrapper here for that reason — the
    /// throwing entry point is on the lower-level `SPUUpdater`, not on
    /// this controller.
    func start() {
        controller.startUpdater()
    }

    /// The user-initiated "Check for Updates" action — shows Sparkle's
    /// standard progress UI and, per its own docs, verbosely reports
    /// whatever it finds (up to date / update available / error).
    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }
}

/// Receives Sparkle's show/hide callbacks purely to (a) bring the app
/// forward so its UI is actually visible even when glance is currently
/// `.accessory`/windowless, and (b) expose `isPresentingUpdateUI` above.
/// See `SPUStandardUserDriverDelegate`'s header for the full callback set —
/// every method on it is optional, so only the three needed here are
/// implemented.
@MainActor
private final class UpdatePresentationDelegate: NSObject, SPUStandardUserDriverDelegate {
    private(set) var isPresentingUpdateUI = false

    /// Fires before ANY modal alert, including the plain "You're up to
    /// date" sheet from a manual check — the common case with no release
    /// published yet, and exactly the path that needs the app brought
    /// forward since it's user-initiated from the menu bar.
    func standardUserDriverWillShowModalAlert() {
        beginPresenting()
    }

    /// Fires before Sparkle shows an actual found-update window (as
    /// opposed to a plain alert) — covers the real update path once
    /// releases exist.
    func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
    ) {
        beginPresenting()
    }

    /// The session-end hook — not "did dismiss the alert," which Sparkle
    /// doesn't expose, but this fires for every way a session can end
    /// (dismissed, skipped, errored, or installed), so it's the correct
    /// single place to clear the flag.
    func standardUserDriverWillFinishUpdateSession() {
        isPresentingUpdateUI = false
    }

    private func beginPresenting() {
        isPresentingUpdateUI = true
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}
