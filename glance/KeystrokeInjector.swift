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
    case eventCreationFailed

    var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            return "Accessibility permission required. Open System Settings → Privacy & Security → Accessibility and enable glance."
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
    /// caller can hold the plaintext as a zero-able buffer; the brief internal `String` decode is scoped to this call. Blocking.
    nonisolated static func typeAndReturn(_ passwordBytes: Data) throws {
        guard isAccessibilityTrusted() else {
            throw KeystrokeError.accessibilityNotGranted
        }
        guard let text = String(data: passwordBytes, encoding: .utf8) else {
            throw KeystrokeError.eventCreationFailed
        }
        let source = CGEventSource(stateID: .hidSystemState)
        // Whatever woke the Mac — a keypress, a trackpad tap that landed on the field — is already sitting in the
        // password box. Typing on top of it appends, so the field holds `<junk><password>` and login rejects a password
        // the user knows is right.
        try clearFocusedField(source: source)
        for char in text {
            try postUnicode(String(char), source: source)
        }
        try postReturn(source: source)
    }

    /// Select-all then delete, so injection always starts from an empty field.
    private nonisolated static func clearFocusedField(source: CGEventSource?) throws {
        let aKey: CGKeyCode = 0x00
        let deleteKey: CGKeyCode = 0x33

        guard let selectDown = CGEvent(keyboardEventSource: source, virtualKey: aKey, keyDown: true),
              let selectUp = CGEvent(keyboardEventSource: source, virtualKey: aKey, keyDown: false),
              let deleteDown = CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: true),
              let deleteUp = CGEvent(keyboardEventSource: source, virtualKey: deleteKey, keyDown: false) else {
            throw KeystrokeError.eventCreationFailed
        }

        selectDown.flags = .maskCommand
        selectUp.flags = .maskCommand
        deleteDown.flags = []
        deleteUp.flags = []

        selectDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: keyInterval)
        selectUp.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: keyInterval)
        deleteDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: keyInterval)
        deleteUp.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: keyInterval)
    }

    /// Per-character Unicode injection — bypasses keyboard layout issues.
    private nonisolated static func postUnicode(_ unicode: String, source: CGEventSource?) throws {
        let utf16 = Array(unicode.utf16)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            throw KeystrokeError.eventCreationFailed
        }
        // `.hidSystemState` events inherit the live hardware modifier state, so Caps Lock — or a modifier the user is
        // still physically holding from waking the Mac — rides along and corrupts every character.
        keyDown.flags = []
        keyUp.flags = []
        utf16.withUnsafeBufferPointer { buf in
            if let base = buf.baseAddress {
                keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: base)
                keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: base)
            }
        }
        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: keyInterval)
        keyUp.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: keyInterval)
    }

    /// Physical Return key (virtual key 0x24).
    private nonisolated static func postReturn(source: CGEventSource?) throws {
        let returnKey: CGKeyCode = 0x24
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false) else {
            throw KeystrokeError.eventCreationFailed
        }
        // A held Shift or Control turns this into a different shortcut and the field never submits.
        keyDown.flags = []
        keyUp.flags = []
        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: keyInterval)
        keyUp.post(tap: .cghidEventTap)
    }

    private nonisolated static let keyInterval: TimeInterval = 0.012
}
