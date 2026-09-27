//
//  KeystrokeInjector.swift
//  glance
//
//  Synthesizes keystrokes via CGEvent, posted at the HID tap so they reach the lock screen's secure text field.
//

import Foundation
import ApplicationServices
import CoreGraphics

enum KeystrokeError: LocalizedError {
    case accessibilityNotGranted
    case authorizationExpired
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            return "Accessibility permission required. Open System Settings → Privacy & Security → Accessibility and enable glance."
        case .authorizationExpired:
            return "Unlock authorization expired."
        case .eventCreationFailed:
            return "Couldn't create CGEvent for keystroke."
        }
    }
}

enum KeystrokeInjector {
    /// Returns true if the app has Accessibility permission (no prompt).
    nonisolated static func isAccessibilityTrusted() -> Bool {
        return AXIsProcessTrusted()
    }

    /// Triggers the system prompt to grant Accessibility (deep links to System Settings).
    @discardableResult
    nonisolated static func promptForAccessibility() -> Bool {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue()
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Types the UTF-8 bytes into whatever has keyboard focus, then presses Return. Takes `Data` rather than `String` so the
    /// caller can hold the plaintext as a zero-able buffer; the brief internal `String` decode is scoped to this call.
    @MainActor static func typeAndReturn(_ passwordBytes: Data, stillAuthorized: @MainActor () -> Bool = { true },
                                        accessibilityCheck: () -> Bool = { KeystrokeInjector.isAccessibilityTrusted() },
                                        postEvent: (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) }) async throws {
        guard accessibilityCheck() else { throw KeystrokeError.accessibilityNotGranted }
        guard let text = String(data: passwordBytes, encoding: .utf8) else { throw KeystrokeError.eventCreationFailed }
        let source = CGEventSource(stateID: .hidSystemState)
        guard stillAuthorized() else { throw KeystrokeError.authorizationExpired }
        try await postKey(0x7C, flags: .maskCommand, source: source, authorized: stillAuthorized, post: postEvent)
        guard stillAuthorized() else { throw KeystrokeError.authorizationExpired }
        try await postKey(0x33, flags: .maskCommand, source: source, authorized: stillAuthorized, post: postEvent)
        for char in text {
            guard stillAuthorized() else { throw KeystrokeError.authorizationExpired }
            let utf16 = Array(String(char).utf16)
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
                throw KeystrokeError.eventCreationFailed
            }
            utf16.withUnsafeBufferPointer { buffer in
                if let base = buffer.baseAddress {
                    down.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
                    up.keyboardSetUnicodeString(stringLength: buffer.count, unicodeString: base)
                }
            }
            try await postPair(down: down, up: up, authorized: stillAuthorized, post: postEvent)
        }
        guard stillAuthorized() else { throw KeystrokeError.authorizationExpired }
        try await postKey(0x24, source: source, authorized: stillAuthorized, post: postEvent)
    }

    @MainActor private static func postPair(down: CGEvent, up: CGEvent, authorized: () -> Bool, post: (CGEvent) -> Void) async throws {
        try Task.checkCancellation()
        guard authorized() else { throw KeystrokeError.authorizationExpired }
        post(down)
        // Always release a posted key even if cancellation interrupts the delay.
        var released = false
        defer { if !released { post(up) } }
        try await Task.sleep(for: .milliseconds(12))
        post(up)
        released = true
        try await Task.sleep(for: .milliseconds(12))
    }

    @MainActor private static func postKey(_ key: CGKeyCode, flags: CGEventFlags = [], source: CGEventSource?, authorized: () -> Bool, post: (CGEvent) -> Void) async throws {
        try Task.checkCancellation()
        guard authorized() else { throw KeystrokeError.authorizationExpired }
        var commandUp: CGEvent?
        if flags.contains(.maskCommand) {
            guard let down = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: true),
                  let up = CGEvent(keyboardEventSource: source, virtualKey: 0x37, keyDown: false) else {
                throw KeystrokeError.eventCreationFailed
            }
            down.flags = .maskCommand
            up.flags = []
            commandUp = up
            post(down)
        }
        defer { if let commandUp { post(commandUp) } }
        try Task.checkCancellation()
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
            throw KeystrokeError.eventCreationFailed
        }
        down.flags = flags; up.flags = flags
        try await postPair(down: down, up: up, authorized: authorized, post: post)
    }
}
