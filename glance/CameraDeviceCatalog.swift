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
    /// False for a device macOS lists but can't actually deliver frames from —
    /// in practice the built-in FaceTime camera while the lid is closed.
    let isUsable: Bool
}

enum CameraDeviceCatalog {
    private static let deviceTypes: [AVCaptureDevice.DeviceType] = [
        .builtInWideAngleCamera, .external, .continuityCamera
    ]

    private static func discoveredDevices() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    /// A clamshelled MacBook still *reports* its built-in camera as connected; it's
    /// only `isSuspended` that gives it away. Opening one produces a session that
    /// runs but never publishes a frame — a black preview with no error.
    private static func isUsable(_ device: AVCaptureDevice) -> Bool {
        device.isConnected && !device.isSuspended
    }

    static func availableDevices() -> [CameraDevice] {
        discoveredDevices().map {
            CameraDevice(id: $0.uniqueID, name: $0.localizedName, isUsable: isUsable($0))
        }
    }

    /// Devices that can actually deliver frames right now — what a picker shown
    /// during onboarding should offer.
    static func usableDevices() -> [CameraDevice] {
        availableDevices().filter(\.isUsable)
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

    /// Display-specific override, then flat default, then the best usable camera.
    ///
    /// Every stage is filtered through `isUsable`, so a saved preference pointing at
    /// a camera that's currently unavailable (unplugged dock, closed lid) degrades to
    /// the next candidate instead of opening a device that will never produce frames.
    static func resolvedDevice() -> AVCaptureDevice? {
        let settings = GlanceSettings.shared
        let preferredID = isUsingBuiltInDisplay()
            ? (settings.builtInDisplayCameraID ?? settings.defaultCameraID)
            : (settings.externalDisplayCameraID ?? settings.defaultCameraID)

        if let preferredID, let device = AVCaptureDevice(uniqueID: preferredID), isUsable(device) {
            return device
        }

        if let builtIn = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
           isUsable(builtIn) {
            return builtIn
        }

        // Clamshell/headless case: no usable built-in, so take whatever external or
        // Continuity camera is attached.
        if let external = discoveredDevices().first(where: isUsable) {
            return external
        }

        let systemDefault = AVCaptureDevice.default(for: .video)
        return systemDefault.map(isUsable) == true ? systemDefault : nil
    }
}
