//
//  NotchSkyLight.swift
//  glance
//
//  Private, undocumented SkyLight window-server API — the only way found to make
//  a window visible on the real macOS lock screen. Adapted from Lakr233/SkyLightWindow
//  (MIT) — https://github.com/Lakr233/SkyLightWindow.
//
//  RISK: dlopen's a private Apple framework and calls undocumented C symbols. Apple
//  can change or remove them in any macOS update, and their use would disqualify Mac
//  App Store distribution. `shared` is nil if loading fails, so the app degrades to
//  "no lock-screen visibility" instead of crashing.
//
//  Toggle delegation ONLY while the screen is actually locked — see NotchWindowController.
//

import AppKit

/// What Notification Center itself renders at while the screen is locked — higher
/// than the plain `screenLock` level, which is why that one is used here.
private enum SkyLightSpaceLevel: Int32 {
    case notificationCenterAtScreenLock = 400
}

final class NotchSkyLight {
    /// `nil` if the private framework or any symbol couldn't be loaded —
    /// callers must treat that as "lock-screen visibility unavailable,"
    /// not a crash.
    static let shared: NotchSkyLight? = NotchSkyLight()

    private let connection: Int32
    private let space: UInt64
    private var isSpaceDestroyed = false
    private var terminationObserver: NSObjectProtocol?

    private typealias F_SLSMainConnectionID = @convention(c) () -> Int32
    private typealias F_SLSSpaceCreate = @convention(c) (Int32, Int32, CFDictionary?) -> UInt64
    private typealias F_SLSSpaceDestroy = @convention(c) (Int32, UInt64) -> Int32
    private typealias F_SLSSpaceSetAbsoluteLevel = @convention(c) (Int32, UInt64, Int32) -> Int32
    private typealias F_SLSShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias F_SLSHideSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias F_SLSSpaceAddWindowsAndRemoveFromSpaces = @convention(c) (Int32, UInt64, CFArray, Int32) -> Int32
    private typealias F_SLSRemoveWindowsFromSpaces = @convention(c) (Int32, CFArray, CFArray) -> Int32

    private let spaceDestroy: F_SLSSpaceDestroy
    private let hideSpaces: F_SLSHideSpaces
    private let addWindowsAndRemoveFromSpaces: F_SLSSpaceAddWindowsAndRemoveFromSpaces
    private let removeWindowsFromSpaces: F_SLSRemoveWindowsFromSpaces

    private init?() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
            RTLD_NOW
        ) else { return nil }

        guard
            let mainConnectionSym = dlsym(handle, "SLSMainConnectionID"),
            let spaceCreateSym = dlsym(handle, "SLSSpaceCreate"),
            let spaceDestroySym = dlsym(handle, "SLSSpaceDestroy"),
            let setLevelSym = dlsym(handle, "SLSSpaceSetAbsoluteLevel"),
            let showSpacesSym = dlsym(handle, "SLSShowSpaces"),
            let hideSpacesSym = dlsym(handle, "SLSHideSpaces"),
            let addRemoveSym = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces"),
            let removeSym = dlsym(handle, "SLSRemoveWindowsFromSpaces")
        else { return nil }

        let mainConnectionID = unsafeBitCast(mainConnectionSym, to: F_SLSMainConnectionID.self)
        let spaceCreate = unsafeBitCast(spaceCreateSym, to: F_SLSSpaceCreate.self)
        spaceDestroy = unsafeBitCast(spaceDestroySym, to: F_SLSSpaceDestroy.self)
        let setAbsoluteLevel = unsafeBitCast(setLevelSym, to: F_SLSSpaceSetAbsoluteLevel.self)
        let showSpaces = unsafeBitCast(showSpacesSym, to: F_SLSShowSpaces.self)
        hideSpaces = unsafeBitCast(hideSpacesSym, to: F_SLSHideSpaces.self)
        addWindowsAndRemoveFromSpaces = unsafeBitCast(addRemoveSym, to: F_SLSSpaceAddWindowsAndRemoveFromSpaces.self)
        removeWindowsFromSpaces = unsafeBitCast(removeSym, to: F_SLSRemoveWindowsFromSpaces.self)

        connection = mainConnectionID()
        // The `1` flag is load-bearing: any other value causes Finder to draw desktop icons into this space.
        let createdSpace = spaceCreate(connection, 1, nil)
        guard createdSpace != 0 else { return nil }
        space = createdSpace
        _ = setAbsoluteLevel(connection, space, SkyLightSpaceLevel.notificationCenterAtScreenLock.rawValue)
        _ = showSpaces(connection, [NSNumber(value: space)] as CFArray)

        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.destroySpaceIfNeeded()
            }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
    }

    private func destroySpaceIfNeeded() {
        guard !isSpaceDestroyed else { return }
        isSpaceDestroyed = true
        _ = hideSpaces(connection, [NSNumber(value: space)] as CFArray)
        _ = spaceDestroy(connection, space)
    }

    /// Adds `window` to the elevated-level space, making it visible on the
    /// lock screen. Call only while actually locked.
    func delegate(_ window: NSWindow) {
        guard !isSpaceDestroyed else { return }
        _ = addWindowsAndRemoveFromSpaces(
            connection,
            space,
            [NSNumber(value: window.windowNumber)] as CFArray,
            7
        )
    }

    /// Removes `window` from the elevated-level space, returning it to
    /// normal window-server behavior. Call as soon as the screen unlocks.
    func undelegate(_ window: NSWindow) {
        guard !isSpaceDestroyed else { return }
        _ = removeWindowsFromSpaces(
            connection,
            [NSNumber(value: window.windowNumber)] as CFArray,
            [NSNumber(value: space)] as CFArray
        )
    }
}
