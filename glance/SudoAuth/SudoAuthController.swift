//
//  SudoAuthController.swift
//  glance
//
//  Owns the sudo face-auth socket server and keeps it in sync with session
//  lock state + the Settings toggle.
//

import Foundation
import Observation

@Observable
@MainActor
final class SudoAuthController {
    private let server = SudoAuthServer()
    private var sessionObserver: NSObjectProtocol?

    private(set) var isListenerActive = false
    private(set) var pamInstallStatus: SudoAuthInstaller.Status = .unknown
    private(set) var lastInstallError: String?

    var isSudoFaceEnabled: Bool {
        get { GlanceSettings.shared.isSudoFaceEnabled }
        set {
            GlanceSettings.shared.isSudoFaceEnabled = newValue
            Task { await applyPreferenceChange(enabled: newValue) }
        }
    }

    init() {
        sessionObserver = NotificationCenter.default.addObserver(
            forName: .secureCredentialSessionDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshInstallStatus()
                self?.reconcileListener()
            }
        }
        refreshInstallStatus()
        reconcileListener()
    }

    func refreshInstallStatus() {
        pamInstallStatus = SudoAuthInstaller.currentStatus()
    }

    func reconcileListener() {
        refreshInstallStatus()
        let unlocked = SecureCredentialManager.isSessionUnlocked
        let enabled = GlanceSettings.shared.isSudoFaceEnabled
        let pamOK = pamInstallStatus.isOperational
        let shouldListen = enabled && unlocked && pamOK
        if shouldListen {
            server.startIfNeeded()
        } else {
            server.stop()
        }
        isListenerActive = server.isListening
        if enabled && pamOK && !unlocked {
            lastInstallError = "Unlock session (menu bar → Session Locked) — Face for sudo needs an unlocked session."
        } else if enabled && isListenerActive {
            lastInstallError = nil
        }
    }

    private func applyPreferenceChange(enabled: Bool) async {
        lastInstallError = nil
        if enabled {
            refreshInstallStatus()
            // Already on disk + in sudo_local — skip privileged install (osascript
            // can't write /etc/pam.d and was flipping the toggle off).
            if pamInstallStatus.isOperational {
                reconcileListener()
                if !SecureCredentialManager.isSessionUnlocked {
                    lastInstallError = "Unlock session (menu bar) so Face for sudo can listen."
                }
                return
            }
            do {
                try await SudoAuthInstaller.install()
                refreshInstallStatus()
                reconcileListener()
                if !SecureCredentialManager.isSessionUnlocked {
                    lastInstallError = "Unlock session (menu bar) so Face for sudo can listen."
                }
            } catch {
                refreshInstallStatus()
                if pamInstallStatus.isOperational {
                    lastInstallError = "Install helper failed, but PAM is already set up. Unlock session to listen."
                    reconcileListener()
                } else {
                    GlanceSettings.shared.isSudoFaceEnabled = false
                    lastInstallError = error.localizedDescription
                    reconcileListener()
                }
            }
        } else {
            // Stop listening only — leave PAM installed (avoids blocked /etc write).
            lastInstallError = nil
            refreshInstallStatus()
            reconcileListener()
        }
    }
}
