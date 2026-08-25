//
//  AppEnvironment.swift
//  glance
//
//  Owns the app-wide, long-lived controllers. Hoisted here — constructed
//  once in `glanceApp` — so Settings pages share the exact same instances
//  instead of each spinning up its own LockMonitor/CameraManager/
//  FaceRecognitionPipeline. Without this, e.g. a second FaceUnlockCoordinator
//  would race the first one to arm the lock-screen notch.
//

import Foundation
import Observation

@Observable
@MainActor
final class AppEnvironment {
    let pocController = POCController()
    let faceLabController = FaceLabController()
    let faceUnlockCoordinator: FaceUnlockCoordinator
    /// Held (not just constructed and dropped) because it owns a repeating
    /// timer — letting it deallocate would silently stop enforcing the
    /// auto-lock interval.
    let sessionAutoLocker: SessionAutoLocker
    /// Sparkle auto-update controller — see `Updater/UpdaterController.swift`
    /// and RELEASING.md. Constructed here (not started) so the About page
    /// and `AppDelegate` share the exact same instance; `AppDelegate.
    /// applicationDidFinishLaunching` calls `updater.start()` once.
    let updater = UpdaterController()

    /// Debug/Face Lab sidebar section — hidden by default, revealed by
    /// tapping the app icon on the About page 5 times in a row (see
    /// `AboutSettingsPage`). Deliberately a plain in-memory `var`, never
    /// backed by `UserDefaults`: `AppEnvironment` is constructed fresh every
    /// launch, so this resets to `false` every time with no extra code —
    /// exactly the "always hidden on relaunch" behavior asked for.
    var isDebugSectionRevealed = false

    init() {
        faceUnlockCoordinator = FaceUnlockCoordinator(pocController: pocController)
        sessionAutoLocker = SessionAutoLocker(pocController: pocController)
    }
}
