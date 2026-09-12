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

    /// True if the currently-active screen is the Mac's built-in display
    /// (vs. an external monitor) — used to pick between the built-in/
    /// external camera overrides.
    static func isUsingBuiltInDisplay() -> Bool {
        guard let screen = NSScreen.main,
              let screenNumber = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return true }
        return CGDisplayIsBuiltin(screenNumber) != 0
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
