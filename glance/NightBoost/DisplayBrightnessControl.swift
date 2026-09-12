//
//  DisplayBrightnessControl.swift
//  glance
//
//  Private, undocumented DisplayServices API — macOS has no public way for an app to set display brightness (unlike
//  iOS's UIScreen.brightness). Same posture as NotchSkyLight: dlopen'd at runtime, `shared` is nil if any symbol is
//  missing, and callers degrade to "no brightness boost" rather than crash. Verified to resolve on macOS 26.6 / Apple silicon.
//

import Foundation
import CoreGraphics

final class DisplayBrightnessControl {
    static let shared: DisplayBrightnessControl? = DisplayBrightnessControl()

    private typealias F_GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
    private typealias F_SetBrightness = @convention(c) (CGDirectDisplayID, Float) -> Int32
    private typealias F_CanChangeBrightness = @convention(c) (CGDirectDisplayID) -> Bool

    private let getBrightness: F_GetBrightness
    private let setBrightness: F_SetBrightness
    private let canChangeBrightness: F_CanChangeBrightness

    private init?() {
        guard let handle = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/A/DisplayServices",
            RTLD_NOW
        ) else { return nil }
        guard
            let getSym = dlsym(handle, "DisplayServicesGetBrightness"),
            let setSym = dlsym(handle, "DisplayServicesSetBrightness"),
            let canSym = dlsym(handle, "DisplayServicesCanChangeBrightness")
        else { return nil }
        getBrightness = unsafeBitCast(getSym, to: F_GetBrightness.self)
        setBrightness = unsafeBitCast(setSym, to: F_SetBrightness.self)
        canChangeBrightness = unsafeBitCast(canSym, to: F_CanChangeBrightness.self)
    }

    /// False for displays without software brightness (most external monitors) — a boost there is a no-op by design.
    func canChange(_ display: CGDirectDisplayID) -> Bool {
        canChangeBrightness(display)
    }

    /// 0…1, or nil if the display doesn't report.
    func brightness(of display: CGDirectDisplayID) -> Float? {
        var value: Float = 0
        guard getBrightness(display, &value) == 0 else { return nil }
        return value
    }

    /// Returns false if the display refused. Clamped to 0…1.
    @discardableResult
    func set(_ brightness: Float, on display: CGDirectDisplayID) -> Bool {
        setBrightness(display, min(max(brightness, 0), 1)) == 0
    }
}
