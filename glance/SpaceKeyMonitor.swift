//
//  SpaceKeyMonitor.swift
//  glance
//
//  Detects the space key on the lock screen — the one place normal keyboard
//  observation can't reach.
//
//  The lock screen runs under Secure Event Input, which makes the
//  WindowServer route keys straight to the secure password field and
//  suppress every event-tap/`NSEvent`-monitor path. IOKit HID reads the raw
//  device stream *below* that boundary, which is the only way to see the
//  keypress there — and is why it's gated behind TCC.
//
//  PERMISSION, and why glance never appears under Input Monitoring:
//  the gate is `kTCCServiceListenEvent`, but TCC resolves that check against
//  `kTCCServiceAccessibility` first and answers "granted" if the app holds
//  Accessibility. glance already requires Accessibility to type the password
//  (`KeystrokeInjector`), so `IOHIDCheckAccess` returns `.granted` without
//  ever consulting the Input Monitoring record — which means glance is never
//  registered in, and will never show up under, System Settings → Privacy &
//  Security → Input Monitoring. That absence is correct, not a bug: an app
//  only lands in that list if it asks for HID access *without* Accessibility.
//
//  Isolated to this one file with a graceful-degradation stance (same as
//  NotchSkyLight's private-API isolation): if Input Monitoring isn't granted
//  or `IOHIDManagerOpen` fails, `start()` simply no-ops and the "On space"
//  trigger stays inert rather than crashing.
//
//  PRIVACY: this is a "press space to invoke Face ID" affordance, not a
//  keylogger. The monitor is only ever running while the screen is locked
//  and the user has opted into "On space" (see
//  FaceUnlockCoordinator.updateSpaceMonitor), and the callback inspects
//  nothing but whether the HID usage is the spacebar — no other key is read,
//  stored, or forwarded anywhere.
//

import Foundation
import IOKit.hid
import OSLog

@MainActor
final class SpaceKeyMonitor {
    /// Traces the Input Monitoring handshake, which is otherwise invisible:
    /// TCC decisions happen out of process and failures are silent. Read with
    /// `log stream --predicate 'subsystem == "com.jonathan.glance"'`.
    static let log = Logger(subsystem: "com.jonathan.glance", category: "inputmonitoring")

    /// Runs on the main actor when the space key is pressed down (not on
    /// release, and not per auto-repeat frame beyond the first down).
    var onSpaceKeyDown: (() -> Void)?

    private var manager: IOHIDManager?

    // MARK: - Input Monitoring permission (static — callable without an instance)

    /// The three states TCC actually distinguishes. `denied` matters on its
    /// own: once the user (or a prior silent decision) has said no, no API
    /// can re-prompt — the only route back is System Settings — so the UI
    /// needs to tell those two "not granted" cases apart.
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

    /// True if the app can read the HID keyboard stream. Never prompts.
    ///
    /// In practice this is true whenever Accessibility is granted (see the
    /// file header), so on a working glance install it tracks
    /// `KeystrokeInjector.isAccessibilityTrusted()`.
    static func hasInputMonitoringAccess() -> Bool {
        inputMonitoringAccess == .granted
    }

    /// True when macOS will attribute this process's TCC decisions to a
    /// *different* app — in practice, the app was launched by Xcode's Run
    /// button and inherits Xcode's grants.
    ///
    /// Not the reason glance is absent from the Input Monitoring list (that's
    /// the Accessibility subsumption in the file header), but it does make any
    /// permission reading taken under Xcode untrustworthy: the answer belongs
    /// to Xcode, and a request would register Xcode rather than glance. Test
    /// permission behaviour from an independently launched copy —
    /// `open /path/to/glance.app`, or a build in /Applications.
    ///
    /// Detected via the environment Xcode injects into processes it launches.
    static var isLaunchedByXcode: Bool {
        ProcessInfo.processInfo.environment["__XCODE_BUILT_PRODUCTS_DIR_PATHS"] != nil
    }

    /// Asks for HID listen access.
    ///
    /// Near-always a no-op in glance: the check is already satisfied through
    /// Accessibility, so this returns `true` without prompting and without
    /// registering glance under Input Monitoring. It only does anything for an
    /// install that somehow has no Accessibility grant — in which case the
    /// user needs Accessibility anyway, and the settings notice routes there.
    ///
    /// Skipped under Xcode, where the request would be attributed to Xcode.
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

    /// Begins listening. Idempotent, and a silent no-op without Input
    /// Monitoring — the caller (FaceUnlockCoordinator) gates on
    /// `hasInputMonitoringAccess()` first, but opening still fails closed if
    /// access was revoked between the check and here.
    func start() {
        guard manager == nil else { return }

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        // Match physical keyboards (Generic Desktop → Keyboard), not every
        // HID device, so we only ever get keyboard input values.
        let match: [String: Int] = [
            kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop,
            kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard,
        ]
        IOHIDManagerSetDeviceMatching(mgr, match as CFDictionary)

        // The callback is a capture-less C function; `self` is threaded
        // through the context pointer. `passUnretained` is safe because this
        // object owns `mgr` and always `stop()`s (unregistering) before it's
        // deallocated.
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(mgr, { context, _, _, value in
            guard let context else { return }
            let element = IOHIDValueGetElement(value)
            guard IOHIDElementGetUsagePage(element) == UInt32(kHIDPage_KeyboardOrKeypad),
                  IOHIDElementGetUsage(element) == UInt32(kHIDUsage_KeyboardSpacebar),
                  IOHIDValueGetIntegerValue(value) == 1 // key-down only
            else { return }
            let monitor = Unmanaged<SpaceKeyMonitor>.fromOpaque(context).takeUnretainedValue()
            // Scheduled on the main run loop, so this already fires on the
            // main thread; hop onto the main actor to satisfy isolation.
            Task { @MainActor in monitor.onSpaceKeyDown?() }
        }, context)

        IOHIDManagerScheduleWithRunLoop(mgr, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)

        // The only ground truth about HID access — `IOHIDCheckAccess` reports
        // what TCC would allow, this reports what actually happened. Logged
        // because a failure here is otherwise a silent no-op on the lock
        // screen, where nothing is watching.
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
        // `stop()` is main-actor isolated and by construction the monitor is
        // always stopped before teardown (on unlock/disable), so there's
        // nothing to unwind here.
    }
}
