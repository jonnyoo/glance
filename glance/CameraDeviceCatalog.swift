//
//  CameraDeviceCatalog.swift
//  glance
//
//  Resolves the app's camera preference (flat default, or split by built-in vs. external display) into the device to open.
//

import AVFoundation
import AppKit

struct CameraDevice: Identifiable, Hashable {
    let id: String // AVCaptureDevice.uniqueID
    let name: String
}

enum CameraDeviceCatalog {
    static func availableDevices() -> [CameraDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
            mediaType: .video,
            position: .unspecified
        )
        return discovery.devices.map { CameraDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// True if the display glance targets is the Mac's built-in display
    /// (vs. an external monitor) — used to pick between the built-in/
    /// external camera overrides. Not `NSScreen.main`: that follows the
    /// key window, which is arbitrary at the lock screen.
    static func isUsingBuiltInDisplay() -> Bool {
        targetsBuiltInDisplay(
            pinnedID: GlanceSettings.shared.preferredDisplayID,
            screens: NSScreen.screens.compactMap { TargetDisplay($0) },
            main: NSScreen.main.flatMap { TargetDisplay($0) }
        )
    }

    /// The display-side facts `targetsBuiltInDisplay` needs, split from `NSScreen` so the choice is testable.
    struct TargetDisplay {
        let number: CGDirectDisplayID
        let uuid: String?
        let isBuiltIn: Bool

        init(number: CGDirectDisplayID, uuid: String?, isBuiltIn: Bool) {
            self.number = number
            self.uuid = uuid
            self.isBuiltIn = isBuiltIn
        }

        init?(_ screen: NSScreen) {
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return nil }
            let uuid = CGDisplayCreateUUIDFromDisplayID(number)?.takeRetainedValue()
            self.init(
                number: number,
                uuid: uuid.flatMap { CFUUIDCreateString(nil, $0) as String? },
                isBuiltIn: CGDisplayIsBuiltin(number) != 0
            )
        }

        /// A saved display id is a display UUID or, on installs from before UUIDs, a `CGDirectDisplayID` number.
        /// Delegates to `DisplayMath` so the camera override and the display picker share one matching rule.
        func matches(displayID: String) -> Bool {
            DisplayMath.savedID(displayID, matchesUUID: uuid, number: number)
        }
    }

    /// Decided from the pin and the connected screens directly, rather than through `NotchGeometry.preferredScreen()`,
    /// so the rule stays testable offline and camera choice never depends on overlay placement code. It mirrors that
    /// rule: a connected pin wins; unpinned, the built-in panel wins whenever one is connected (a notched screen is
    /// always built-in), and only then `NSScreen.main`. Deliberately not "notch, else main": on a notchless laptop that
    /// is the key window's screen again.
    static func targetsBuiltInDisplay(pinnedID: String?, screens: [TargetDisplay], main: TargetDisplay?) -> Bool {
        if let pinnedID, let pinned = screens.first(where: { $0.matches(displayID: pinnedID) }) {
            return pinned.isBuiltIn
        }
        if screens.contains(where: { $0.isBuiltIn }) {
            return true
        }
        return main?.isBuiltIn ?? true
    }

    /// The screen the active camera physically sits on — the only display whose light actually reaches the user's face.
    /// `nil` when that can't be determined, so callers skip illuminating rather than light a monitor the camera is not
    /// facing (which would backlight the subject and make auto-exposure pull the face *darker*).
    static func screenForActiveCamera() -> NSScreen? {
        guard let device = resolvedDevice() else { return nil }
        guard device.deviceType == .builtInWideAngleCamera else {
            // An external or Continuity camera can sit anywhere; the display it faces is unknowable from here.
            return nil
        }
        return NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID)
                .map { CGDisplayIsBuiltin($0) != 0 } ?? false
        }
    }

    /// Display-specific override, then flat default, then the system default camera.
    static func resolvedDevice() -> AVCaptureDevice? {
        let settings = GlanceSettings.shared
        let preferredID = isUsingBuiltInDisplay()
            ? (settings.builtInDisplayCameraID ?? settings.defaultCameraID)
            : (settings.externalDisplayCameraID ?? settings.defaultCameraID)

        if let preferredID, let device = AVCaptureDevice(uniqueID: preferredID) {
            return device
        }
        return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
            ?? AVCaptureDevice.default(for: .video)
    }
}
