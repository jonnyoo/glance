//
//  AppEnvironment.swift
//  glance
//
//  Owns the app-wide, long-lived controllers that used to live inside
//  individual debug-window views (each `@State private var` scoped to that
//  view, dying with it). Hoisted here — constructed once in `glanceApp` —
//  so the Settings window's separate pages can share the exact same
//  instances instead of each spinning up its own LockMonitor/CameraManager/
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

    init() {
        faceUnlockCoordinator = FaceUnlockCoordinator(pocController: pocController)
    }
}
