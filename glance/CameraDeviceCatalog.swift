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
    private static func discoveredDevices() -> [AVCaptureDevice] {
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera, .external]
        if GlanceSettings.shared.allowContinuityCamera { types.append(.continuityCamera) }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified)
        return discovery.devices.filter {
            GlanceSettings.shared.allowContinuityCamera || !$0.isContinuityCamera
        }
    }

    static func availableDevices() -> [CameraDevice] {
        discoveredDevices().map { CameraDevice(id: $0.uniqueID, name: $0.localizedName) }
    }

    /// A saved choice must not silently fall back to a different camera while
    /// USB IR capture temporarily removes the selected BRIO from macOS.
    static func device(preferredID: String?) -> AVCaptureDevice? {
        let devices = discoveredDevices()
        if let preferredID { return devices.first { $0.uniqueID == preferredID } }
        return devices.first { $0.deviceType == .builtInWideAngleCamera && !$0.isContinuityCamera }
            ?? devices.first
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

    /// Display-specific override, then flat default, then the system default camera.
    static func resolvedDevice() -> AVCaptureDevice? {
        let settings = GlanceSettings.shared
        let preferredID = isUsingBuiltInDisplay()
            ? (settings.builtInDisplayCameraID ?? settings.defaultCameraID)
            : (settings.externalDisplayCameraID ?? settings.defaultCameraID)

        return device(preferredID: preferredID)
    }
}
