//
//  NotchSkyLight.swift
//  glance
//
//  Private, undocumented SkyLight window-server API — the only way found
//  to make a window visible on the real macOS lock screen. Phase 0 of the
//  notch overlay plan spiked plain NSWindow.level values (.mainMenu + 3,
//  .screenSaver) and confirmed neither appears there.
//
//  Adapted from the real, verified implementation in Lakr233/SkyLightWindow
//  (MIT license) — https://github.com/Lakr233/SkyLightWindow — which
//  Boring Notch also depends on for this exact purpose. Fetched and read
//  directly rather than reconstructed from memory, since guessing at
//  private C symbol sequences is exactly the kind of thing worth getting
//  from a verified source. The `undelegate` counterpart (the package only
//  ships one-way delegation) mirrors Boring Notch's own addition of the
//  matching `SLSRemoveWindowsFromSpaces` call.
//
//  RISK, stated plainly: this dlopen's a private Apple framework and calls
//  undocumented C symbols. Apple can change or remove them in any macOS
//  update with no warning, and their use would disqualify the app from Mac
//  App Store distribution. Isolated to this one file with `shared` as an
//  Optional (nil if dlopen/dlsym fail for any reason, including a future
//  OS no longer exposing these symbols) so the rest of the app degrades to
//  "no lock-screen visibility" instead of crashing if this ever breaks.
//
//  Toggle delegation ONLY while the screen is actually locked — see
//  NotchWindowController. Never leave a window delegated during normal use.
//

import AppKit

/// Absolute privilege levels for the private CGS/SkyLight space system.
/// `notificationCenterAtScreenLock` is what Notification Center itself
/// renders at while the screen is locked — higher than the plain
/// `screenLock` level, which is why that one is used here.
private enum SkyLightSpaceLevel: Int32 {
    case notificationCenterAtScreenLock = 400
}

final class NotchSkyLight {
    /// `nil` if the private framework or any symbol couldn't be loaded —
    /// callers must treat that as "lock-screen visibility unavailable,"
    /// not a crash.
    static let shared: NotchSkyLight? = NotchSkyLight()

    private let connection: Int32
    private let space: Int32

    private typealias F_SLSMainConnectionID = @convention(c) () -> Int32
    private typealias F_SLSSpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias F_SLSSpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias F_SLSShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias F_SLSSpaceAddWindowsAndRemoveFromSpaces = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32
    private typealias F_SLSRemoveWindowsFromSpaces = @convention(c) (Int32, CFArray, CFArray) -> Int32

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
            let setLevelSym = dlsym(handle, "SLSSpaceSetAbsoluteLevel"),
            let showSpacesSym = dlsym(handle, "SLSShowSpaces"),
            let addRemoveSym = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces"),
            let removeSym = dlsym(handle, "SLSRemoveWindowsFromSpaces")
        else { return nil }

        let mainConnectionID = unsafeBitCast(mainConnectionSym, to: F_SLSMainConnectionID.self)
        let spaceCreate = unsafeBitCast(spaceCreateSym, to: F_SLSSpaceCreate.self)
        let setAbsoluteLevel = unsafeBitCast(setLevelSym, to: F_SLSSpaceSetAbsoluteLevel.self)
        let showSpaces = unsafeBitCast(showSpacesSym, to: F_SLSShowSpaces.self)
        addWindowsAndRemoveFromSpaces = unsafeBitCast(addRemoveSym, to: F_SLSSpaceAddWindowsAndRemoveFromSpaces.self)
        removeWindowsFromSpaces = unsafeBitCast(removeSym, to: F_SLSRemoveWindowsFromSpaces.self)

        connection = mainConnectionID()
        // The `1` flag here is load-bearing, per Boring Notch's own
        // comment on this exact call: any other value causes Finder to
        // draw desktop icons into this space.
        space = spaceCreate(connection, 1, 0)
        _ = setAbsoluteLevel(connection, space, SkyLightSpaceLevel.notificationCenterAtScreenLock.rawValue)
        _ = showSpaces(connection, [space] as CFArray)
    }

    /// Adds `window` to the elevated-level space, making it visible on the
    /// lock screen. Call only while actually locked.
    func delegate(_ window: NSWindow) {
        _ = addWindowsAndRemoveFromSpaces(connection, space, [window.windowNumber] as CFArray, 7)
    }

    /// Removes `window` from the elevated-level space, returning it to
    /// normal window-server behavior. Call as soon as the screen unlocks.
    func undelegate(_ window: NSWindow) {
        _ = removeWindowsFromSpaces(connection, [window.windowNumber] as CFArray, [space] as CFArray)
    }
}
