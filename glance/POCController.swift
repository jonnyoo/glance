//
//  POCController.swift
//  glance
//
//  Orchestration for the credential-storage POC: wires LockMonitor and
//  SecureCredentialManager to KeystrokeInjector and exposes status for the UI.
//

import Foundation
import Observation

@Observable
@MainActor
final class POCController {
    let lockMonitor = LockMonitor()

    var accessibilityGranted: Bool = KeystrokeInjector.isAccessibilityTrusted()

    var hasStoredPassword: Bool = SecureCredentialManager.hasStoredPassword()
    var isSessionUnlocked: Bool = SecureCredentialManager.isSessionUnlocked
    var sessionError: String? = nil

    /// Bound to the setup SecureField. Cleared immediately after a successful save.
    var passwordInput: String = ""

    var autoInjectOnLock: Bool = false
    var statusMessage: String = "Idle"

    private var hasAutoInjectedForCurrentLock = false

    init() {
        observeLockAndWakeEvents()
    }

    /// Re-evaluates auto-inject whenever the lock notification, a wake, or a
    /// sleep transition fires. Wake matters because the lock can happen
    /// while this process is suspended (e.g. closing the lid puts the whole
    /// Mac to sleep right around when the screen locks): the lock
    /// notification never arrives in time, but the very next wake is our
    /// chance to notice the screen is already locked and react.
    private func observeLockAndWakeEvents() {
        withObservationTracking {
            _ = lockMonitor.isScreenLocked
            _ = lockMonitor.wakeEventCount
            _ = lockMonitor.isSleeping
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeLockAndWakeEvents() // re-subscribe — fires once per registration
                // Brief settle delay: right after wake, CGSession's reported
                // state can lag the true state by a beat.
                try? await Task.sleep(nanoseconds: 300_000_000)
                self?.evaluateAutoInject()
            }
        }
    }

    /// Always re-derives the decision from the authoritative CGSession check
    /// rather than the cached `isScreenLocked` notification flag — that flag
    /// is exactly what can go stale across a sleep/wake cycle.
    private func evaluateAutoInject() {
        guard LockMonitor.isScreenActuallyLocked() else {
            hasAutoInjectedForCurrentLock = false
            return
        }

        // `screenIsLocked` fires ~150ms *before* the system actually finishes
        // suspending, so acting on it here would race the imminent sleep and
        // could hit a login window that's about to be torn down — and would
        // consume the one-shot flag below before the real opportunity (wake)
        // arrives. Skip for now; the post-wake re-evaluation (triggered by
        // `wakeEventCount`, once `isSleeping` flips back to false) is what
        // actually fires the injection in that case.
        guard !lockMonitor.isSleeping else { return }

        guard autoInjectOnLock, !hasAutoInjectedForCurrentLock else { return }
        hasAutoInjectedForCurrentLock = true

        Task {
            try? await Task.sleep(nanoseconds: 1_000_000_000) // let the lock screen settle
            await injectStoredPassword(requireAuthoritativeLock: true)
        }
    }

    func refreshAccessibilityStatus() {
        accessibilityGranted = KeystrokeInjector.isAccessibilityTrusted()
    }

    func requestAccessibility() {
        KeystrokeInjector.promptForAccessibility()
    }

    func refreshCredentialStatus() {
        hasStoredPassword = SecureCredentialManager.hasStoredPassword()
        isSessionUnlocked = SecureCredentialManager.isSessionUnlocked
    }

    // MARK: - Session (Touch ID gate)

    /// Must succeed before `savePassword()` or `injectStoredPassword()` will do anything.
    func unlockSession() async {
        sessionError = nil
        do {
            try await Task.detached(priority: .userInitiated) {
                try SecureCredentialManager.unlockSession(reason: "Authenticate to set up or use glance")
            }.value
            isSessionUnlocked = true
        } catch {
            isSessionUnlocked = false
            sessionError = error.localizedDescription
        }
    }

    func lockSession() {
        SecureCredentialManager.lockSession()
        isSessionUnlocked = false
    }

    // MARK: - Setup flow

    /// Encrypts and stores `passwordInput`. Requires the session to already
    /// be unlocked (Touch ID happens in `unlockSession()`, not here).
    func savePassword() async {
        guard !passwordInput.isEmpty else {
            statusMessage = "Enter a password first."
            return
        }
        let plaintext = passwordInput
        passwordInput = ""

        do {
            try await Task.detached(priority: .userInitiated) {
                guard var bytes = plaintext.data(using: .utf8) else {
                    throw SecureCredentialError.emptyPassword
                }
                defer { bytes.resetBytes(in: 0..<bytes.count) }
                try SecureCredentialManager.savePassword(bytes)
            }.value
            statusMessage = "Password saved and encrypted."
            hasStoredPassword = true
        } catch {
            statusMessage = "Save failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Injection

    /// Reads + decrypts + injects the stored password, zeroing the plaintext
    /// buffer before returning. When `requireAuthoritativeLock` is true (the
    /// auto-trigger path), refuses to inject unless the CGSession dictionary
    /// confirms the screen is actually locked.
    func injectStoredPassword(requireAuthoritativeLock: Bool = false) async {
        guard KeystrokeInjector.isAccessibilityTrusted() else {
            statusMessage = "Accessibility not granted — open System Settings and enable glance."
            return
        }
        guard SecureCredentialManager.isSessionUnlocked else {
            statusMessage = "Session locked — authenticate with Touch ID first."
            return
        }

        if requireAuthoritativeLock {
            guard LockMonitor.isScreenActuallyLocked() else {
                statusMessage = "Skipped: CGSession reports screen is not actually locked."
                return
            }
        }

        statusMessage = "Injecting…"
        do {
            try await Task.detached(priority: .userInitiated) {
                var bytes = try SecureCredentialManager.readPassword()
                defer { bytes.resetBytes(in: 0..<bytes.count) }
                try KeystrokeInjector.typeAndReturn(bytes)
            }.value
            statusMessage = "Injected stored password + Return at \(Date().formatted(date: .omitted, time: .standard))"
        } catch {
            statusMessage = "Injection failed: \(error.localizedDescription)"
        }
    }
}
