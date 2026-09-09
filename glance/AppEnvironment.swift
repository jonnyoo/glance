//
//  AppEnvironment.swift
//  glance
//
//  Owns app-wide, long-lived controllers so Settings pages share one instance instead of racing duplicates.
//

import Foundation
import Observation

@Observable
@MainActor
final class AppEnvironment {
    let pocController = POCController()
    let faceLabController = FaceLabController()
    let faceUnlockCoordinator: FaceUnlockCoordinator
    /// Held, not just constructed — owns a repeating timer that would silently stop enforcing auto-lock if deallocated.
    let sessionAutoLocker: SessionAutoLocker
    /// Constructed here (not started) so the About page and `AppDelegate` share one instance; `AppDelegate` calls `updater.start()`.
    let updater = UpdaterController()

    /// Revealed by tapping the app icon 5 times on the About page. Plain in-memory `var` so it resets on every relaunch.
    var isDebugSectionRevealed = false

    init() {
        faceUnlockCoordinator = FaceUnlockCoordinator(pocController: pocController)
        sessionAutoLocker = SessionAutoLocker(pocController: pocController)
    }
}
