//
//  SystemAuthentication.swift
//  glance
//
//  The Mac's own "prove it's you" prompt — Touch ID, Apple Watch, or the account password. App Lock's way in when a face
//  can't be checked, and the gate on changing which apps are locked. Deliberately independent of Glance's session key:
//  this has to keep working exactly when the session is locked.
//

import Foundation
import LocalAuthentication

enum SystemAuthentication {
    /// False for a cancelled prompt and a failed one alike — callers only care whether the user got through.
    /// Pass a `context` to be able to `invalidate()` it, which dismisses the prompt and resolves this to false.
    ///
    /// The completion-handler form rather than `async`: awaiting it directly would mean handing the non-Sendable
    /// `LAContext` across isolation.
    static func authenticate(reason: String, context: LAContext = LAContext()) async -> Bool {
        await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }

    /// Whether the prompt will offer Touch ID right now, so buttons can be named after what's actually behind them.
    /// Not cached: it changes with the lid closed, or once a finger is enrolled.
    static var offersTouchID: Bool {
        let context = LAContext()
        // `biometryType` is only meaningful once a biometric policy has been evaluated for availability.
        return context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
            && context.biometryType == .touchID
    }
}
