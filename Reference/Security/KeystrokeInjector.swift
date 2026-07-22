//
//  KeystrokeInjector.swift
//  FaceUnlock
//

import Foundation
import ApplicationServices
import CoreGraphics

enum KeystrokeError: LocalizedError {
    case accessibilityNotGranted
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            return "Accessibility permission required. Open System Settings → Privacy & Security → Accessibility and enable FaceUnlock."
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

    /// Types the UTF-8 bytes into whatever has keyboard focus, then presses Return.
    ///
    /// Accepts `Data` (bytes) instead of `String` so the caller can hold the plaintext
    /// as a zero-able buffer. Internally we still briefly decode to `String` (Core
    /// Graphics needs Unicode code units), but that `String` exists only within
    /// this function's scope — dropped as soon as we return.
    ///
    /// Blocking; invoke from a background actor.
    nonisolated static func typeAndReturn(_ passwordBytes: Data) throws {
        guard isAccessibilityTrusted() else {
            throw KeystrokeError.accessibilityNotGranted
        }
        guard let text = String(data: passwordBytes, encoding: .utf8) else {
            throw KeystrokeError.eventCreationFailed
        }
        let source = CGEventSource(stateID: .hidSystemState)
        for char in text {
            try postUnicode(String(char), source: source)
        }
        try postReturn(source: source)
    }

    /// Per-character Unicode injection — bypasses keyboard layout issues.
    private nonisolated static func postUnicode(_ unicode: String, source: CGEventSource?) throws {
        let utf16 = Array(unicode.utf16)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            throw KeystrokeError.eventCreationFailed
        }
        utf16.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: base)
                keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: base)
            }
        }
        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.012)
        keyUp.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.012)
    }

    /// Physical Return key (virtual key 0x24).
    private nonisolated static func postReturn(source: CGEventSource?) throws {
        let returnKey: CGKeyCode = 0x24
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false) else {
            throw KeystrokeError.eventCreationFailed
        }
        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.012)
        keyUp.post(tap: .cghidEventTap)
    }
}
