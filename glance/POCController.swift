//
//  POCController.swift
//  glance
//
//  Orchestration for credential storage: wires SecureCredentialManager to
//  KeystrokeInjector and exposes session/password status for Settings.
//

import Foundation
import Observation

@Observable
@MainActor
final class POCController {
    var accessibilityGranted: Bool = KeystrokeInjector.isAccessibilityTrusted()

    var hasStoredPassword: Bool = SecureCredentialManager.hasStoredPassword()
    var isSessionUnlocked: Bool = SecureCredentialManager.isSessionUnlocked
    var sessionError: String? = nil

    /// Bound to the setup SecureField. Cleared immediately after a successful save.
    var passwordInput: String = ""

    var statusMessage: String = "Idle"

    init() {
        NotificationCenter.default.addObserver(
            forName: .secureCredentialSessionDidChange,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshCredentialStatus()
            }
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
    /// buffer before returning. Defaults `requireAuthoritativeLock` to true so
    /// injection refuses to proceed (and aborts mid-sequence) unless the
    /// CGSession dictionary confirms the screen is actually locked.
    func injectStoredPassword(requireAuthoritativeLock: Bool = true) async {
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
                defer {
                    bytes.withUnsafeMutableBytes { raw in
                        if let base = raw.baseAddress, raw.count > 0 {
                            _ = memset_s(base, raw.count, 0, raw.count)
                        }
                    }
                    bytes.resetBytes(in: 0..<bytes.count)
                }
                try KeystrokeInjector.typeAndReturn(bytes, requireLockedScreen: requireAuthoritativeLock)
            }.value
            statusMessage = "Injected stored password + Return at \(Date().formatted(date: .omitted, time: .standard))"
        } catch {
            statusMessage = "Injection failed: \(error.localizedDescription)"
        }
    }
}
