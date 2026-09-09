//
//  SpaceKeyMonitor.swift
//  glance
//
//  Detects the space key on the lock screen via raw IOKit HID reads — Secure Event Input suppresses every other keyboard tap there.
//
//  glance never appears under Input Monitoring: TCC resolves that gate against Accessibility first, and glance already requires
//  Accessibility to type the password, so `IOHIDCheckAccess` grants without ever registering it there. Correct, not a bug.
//
//  Graceful degradation: if access isn't granted or `IOHIDManagerOpen` fails, `start()` no-ops rather than crashing.
//
//  Not a keylogger: only runs while locked + opted into "On space", and the callback checks only whether the key is the spacebar.
//

import Foundation
import IOKit.hid
import OSLog

@MainActor
final class SpaceKeyMonitor {
    /// Traces the Input Monitoring handshake, otherwise invisible since TCC decisions happen out of process.
    static let log = Logger(subsystem: "com.jonathan.glance", category: "inputmonitoring")

    /// Fires on key-down only, not release or auto-repeat.
    var onSpaceKeyDown: (() -> Void)?

    private var manager: IOHIDManager?

    // MARK: - Input Monitoring permission (static — callable without an instance)

    /// `denied` matters on its own: once set, no API can re-prompt — only System Settings can undo it.
    enum InputMonitoringAccess {
        case granted
        case denied
        case notDetermined
    }

    static var inputMonitoringAccess: InputMonitoringAccess {
        let raw = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)
        let state: InputMonitoringAccess
        switch raw {
        case kIOHIDAccessTypeGranted: state = .granted
        case kIOHIDAccessTypeDenied: state = .denied
        default: state = .notDetermined
        }
        log.info("checkAccess -> \(String(describing: state), privacy: .public) (raw \(raw.rawValue)), xcodeLaunched=\(isLaunchedByXcode, privacy: .public)")
        return state
    }

    /// Never prompts. True whenever Accessibility is granted (see file header), so it tracks `KeystrokeInjector.isAccessibilityTrusted()`.
    static func hasInputMonitoringAccess() -> Bool {
        inputMonitoringAccess == .granted
    }

    /// True when launched by Xcode's Run button, which makes TCC decisions attribute to Xcode, not glance — test permission
    /// behavior from an independently launched copy instead (`open /path/to/glance.app`, or a build in /Applications).
    static var isLaunchedByXcode: Bool {
        ProcessInfo.processInfo.environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil
    }

    /// Near-always a no-op: already satisfied through Accessibility. Skipped under Xcode, where it would attribute to Xcode instead.
    @discardableResult
    static func requestInputMonitoringAccess() -> Bool {
        guard !isLaunchedByXcode else {
            log.error("requestAccess SKIPPED — launched by Xcode, request would be attributed to Xcode")
            return hasInputMonitoringAccess()
        }
        let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        log.info("requestAccess -> \(granted, privacy: .public)")
        return granted
    }

    // MARK: - Lifecycle

    /// Idempotent; fails closed if access was revoked between the caller's check and here.
    func start() {
        guard manager == nil else { return }

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Match physical keyboards only, not every HID device.
        let match: [String: Int] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
        ]
        IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)

        // Capture-less C callback; `self` threaded through the context pointer. `passUnretained` is safe since this object
        // always `stop()`s (unregistering) before deallocation.
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(mgr, { context, _, _, value in
            guard let context else { return }
            let element = IOHIDValueGetElement(value)
            guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_KeyboardOrKeypad),
                  IOHIDElementGetUsage(element) == UInt32(kHIDUsage_KeyboardSpacebar),
                  IOHIDValueGetIntegerValue(value) == 1 // key-down only
            else { return }
            let monitor = Unmanaged<SpaceKeyMonitor>.fromOpaque(context).takeUnretainedValue()
            // Already on the main thread (scheduled on the main run loop); hop onto the main actor to satisfy isolation.
            Task { @MainActor in monitor.onSpaceKeyDown?() }
        }, context)

        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        // Ground truth about HID access (unlike IOHIDCheckAccess); logged since a failure here is a silent no-op on the lock screen.
        let result = IOHIDManagerOpen(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else {
            Self.log.error("IOHIDManagerOpen FAILED (0x\(String(result, radix: 16), privacy: .public)) — space key won't be seen")
            IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            return
        }
        Self.log.info("listening for space on the lock screen")
        manager = mgr
    }

    /// Stops listening. Idempotent.
    func stop() {
        guard let mgr = manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(mgr, IOOptionBits(kIOHIDOptionsTypeNone))
        manager = nil
    }

    deinit {
        // Always stopped before teardown (on unlock/disable), so nothing to unwind here.
    }
}
