//
//  POCController.swift
//  glance
//
//  Minimal orchestration for the lock-screen injection POC: wires LockMonitor
//  to KeystrokeInjector and exposes status for the UI.
//

import Foundation
import Observation

@Observable
@MainActor
final class POCController {
    let lockMonitor = LockMonitor()

    var accessibilityGranted: Bool = KeystrokeInjector.isAccessibilityTrusted()
    var testString: String = "test-injection-123"
    var autoInjectOnLock: Bool = false
    var statusMessage: String = "Idle"

    private var hasAutoInjectedForCurrentLock = false

    init() {
        // React to lock state changes to drive the (opt-in) auto-inject path
        // and reset the once-per-lock guard on unlock.
        withObservationTracking {
            _ = lockMonitor.isScreenLocked
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleLockStateChanged()
            }
        }
    }

    private func handleLockStateChanged() {
        // Re-subscribe for the next change (withObservationTracking fires once per registration).
        withObservationTracking {
            _ = lockMonitor.isScreenLocked
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.handleLockStateChanged()
            }
        }

        if !lockMonitor.isScreenLocked {
            hasAutoInjectedForCurrentLock = false
            return
        }

        guard autoInjectOnLock, !hasAutoInjectedForCurrentLock else { return }
        hasAutoInjectedForCurrentLock = true

        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // let the lock screen settle
            await injectTestString(requireAuthoritativeLock: true)
        }
    }

    func refreshAccessibilityStatus() {
        accessibilityGranted = KeystrokeInjector.isAccessibilityTrusted()
    }

    func requestAccessibility() {
        KeystrokeInjector.promptForAccessibility()
    }

    /// Fires the test injection. When `requireAuthoritativeLock` is true (the
    /// auto-trigger path), refuses to inject unless the CGSession dictionary
    /// confirms the screen is actually locked — the same anti-spoofing gate
    /// the reference implementation uses before real password injection.
    func injectTestString(requireAuthoritativeLock: Bool = false) async {
        guard KeystrokeInjector.isAccessibilityTrusted() else {
            statusMessage = "Accessibility not granted — open System Settings and enable glance."
            return
        }

        if requireAuthoritativeLock {
            guard LockMonitor.isScreenActuallyLocked() else {
                statusMessage = "Skipped: CGSession reports screen is not actually locked."
                return
            }
        }

        let text = testString
        statusMessage = "Injecting…"
        do {
            try await Task.detached(priority: .userInitiated) {
                try KeystrokeInjector.typeAndReturn(text)
            }.value
            statusMessage = "Injected \"\(text)\" + Return at \(Date().formatted(date: .omitted, time: .standard))"
        } catch {
            statusMessage = "Injection failed: \(error.localizedDescription)"
        }
    }
}
