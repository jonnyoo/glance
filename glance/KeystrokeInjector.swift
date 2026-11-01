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
    case invalidUTF8Password
    case screenUnlockedDuringInjection

    var errorDescription: String? {
        switch self {
        case .accessibilityNotGranted:
            return "Accessibility permission required. Open System Settings → Privacy & Security → Accessibility and enable glance."
        case .eventCreationFailed:
            return "Couldn't create CGEvent for keystroke."
        case .invalidUTF8Password:
            return "Stored password could not be decoded as valid UTF-8."
        case .screenUnlockedDuringInjection:
            return "Aborted password injection because the screen is no longer locked."
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

    /// Types the UTF-8 bytes into whatever has keyboard focus, then presses Return. Decodes directly into a mutable
    /// `[UInt16]` buffer wiped with `memset_s` on exit (avoiding non-zeroizable `String` heap copies), uses an isolated
    /// `.privateState` event source so physical held keys/modifiers cannot corrupt output, and re-verifies lock state at
    /// every step when `requireLockedScreen` is true. Blocking.
    nonisolated static func typeAndReturn(_ passwordBytes: Data, requireLockedScreen: Bool = true) throws {
        guard isAccessibilityTrusted() else {
            throw KeystrokeError.accessibilityNotGranted
        }
        guard var utf16 = decodeUTF8ToUTF16(passwordBytes) else {
            throw KeystrokeError.invalidUTF8Password
        }
        defer { zeroizeUTF16Buffer(&utf16) }

        try verifyScreenLockedIfNeeded(requireLockedScreen)
        let source = CGEventSource(stateID: .privateState)
        try clearFocusedField(source: source, requireLockedScreen: requireLockedScreen)
        try verifyScreenLockedIfNeeded(requireLockedScreen)
        try postUnicodeBuffer(utf16, source: source, requireLockedScreen: requireLockedScreen)
        try verifyScreenLockedIfNeeded(requireLockedScreen)
        try postReturn(source: source)
    }

    nonisolated private static func verifyScreenLockedIfNeeded(_ requireLockedScreen: Bool) throws {
        if requireLockedScreen, !LockMonitor.isScreenActuallyLocked() {
            throw KeystrokeError.screenUnlockedDuringInjection
        }
    }

    /// Streams UTF-8 bytes directly into UTF-16 code units without allocating an immutable Swift `String`.
    nonisolated static func decodeUTF8ToUTF16(_ data: Data) -> [UInt16]? {
        var utf16: [UInt16] = []
        utf16.reserveCapacity(data.count)
        var decoder = UTF8()
        var iterator = data.makeIterator()
        while true {
            switch decoder.decode(&iterator) {
            case .scalarValue(let scalar):
                UTF16.encode(scalar) { utf16.append($0) }
            case .emptyInput:
                return utf16
            case .error:
                zeroizeUTF16Buffer(&utf16)
                return nil
            }
        }
    }

    /// Wipes a UTF-16 buffer in place using `memset_s` so the optimizer cannot elide the overwrite as a dead store.
    nonisolated static func zeroizeUTF16Buffer(_ buffer: inout [UInt16]) {
        buffer.withUnsafeMutableBufferPointer { ptr in
            guard let base = ptr.baseAddress, ptr.count > 0 else { return }
            let byteCount = ptr.count * MemoryLayout<UInt16>.stride
            _ = memset_s(base, byteCount, 0, byteCount)
        }
    }

    /// Wipes anything already typed into the focused field (e.g. a stray keypress
    /// on the lock screen) so it isn't prepended to the password: ⌘→ to the end,
    /// then ⌘⌫ to delete back to the start. Both are positional keys, so this
    /// behaves the same on every keyboard layout — unlike ⌘A, whose "A" moves.
    private nonisolated static func clearFocusedField(source: CGEventSource?, requireLockedScreen: Bool) throws {
        let rightArrow: CGKeyCode = 0x7C
        let delete: CGKeyCode = 0x33
        try verifyScreenLockedIfNeeded(requireLockedScreen)
        try postKey(rightArrow, flags: .maskCommand, source: source)
        try verifyScreenLockedIfNeeded(requireLockedScreen)
        try postKey(delete, flags: .maskCommand, source: source)
    }

    /// Posts a virtual key down/up, wrapped in a real ⌘ down/up when `flags`
    /// includes `.maskCommand` — some text fields ignore a bare flag without it.
    private nonisolated static func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags = [], source: CGEventSource?) throws {
        let command: CGKeyCode = 0x37
        let usesCommand = flags.contains(.maskCommand)
        if usesCommand {
            guard let commandDown = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: true) else {
                throw KeystrokeError.eventCreationFailed
            }
            commandDown.flags = .maskCommand
            commandDown.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.012)
        }
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            throw KeystrokeError.eventCreationFailed
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.012)
        keyUp.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.012)
        if usesCommand {
            guard let commandUp = CGEvent(keyboardEventSource: source, virtualKey: command, keyDown: false) else {
                throw KeystrokeError.eventCreationFailed
            }
            commandUp.flags = []
            commandUp.post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.012)
        }
    }

    /// Quartz reliably delivers only a small Unicode payload per keyboard event.
    /// Batching at this conservative limit avoids the undocumented truncation seen
    /// with longer payloads, while replacing one down/up pair per character with
    /// one pair per batch.
    nonisolated private static let maximumUnicodeBatchLength = 20
    nonisolated private static let unicodeEventInterval: TimeInterval = 0.004

    /// Computes UTF-16 slice boundaries of at most `maxBatchLength`, stepping back by one unit when
    /// a batch boundary would split a high/low surrogate pair.
    nonisolated static func splitUTF16BatchRanges(
        _ utf16: [UInt16],
        maxBatchLength: Int = maximumUnicodeBatchLength
    ) -> [Range<Int>] {
        let limit = max(maxBatchLength, 2)
        var ranges: [Range<Int>] = []
        var start = 0
        while start < utf16.count {
            var end = min(start + limit, utf16.count)
            if end < utf16.count,
               end - 1 > start,
               (0xD800...0xDBFF).contains(utf16[end - 1]) {
                end -= 1
            }
            ranges.append(start..<end)
            start = end
        }
        return ranges
    }

    /// Posts the password in small UTF-16 batches. Splitting occurs only between
    /// surrogate pairs, so non-BMP password characters are never corrupted.
    private nonisolated static func postUnicodeBuffer(
        _ utf16: [UInt16],
        source: CGEventSource?,
        requireLockedScreen: Bool
    ) throws {
        let ranges = splitUTF16BatchRanges(utf16, maxBatchLength: maximumUnicodeBatchLength)
        try utf16.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            for range in ranges {
                try verifyScreenLockedIfNeeded(requireLockedScreen)
                try postUnicode(
                    base.advanced(by: range.lowerBound),
                    length: range.count,
                    source: source
                )
            }
        }
    }

    /// Unicode injection bypasses keyboard-layout issues. The password is placed
    /// on a key-down event as a text batch; the matching key-up maintains normal
    /// secure-field event semantics.
    private nonisolated static func postUnicode(
        _ unicode: UnsafePointer<UInt16>,
        length: Int,
        source: CGEventSource?
    ) throws {
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) else {
            throw KeystrokeError.eventCreationFailed
        }
        keyDown.flags = []
        keyUp.flags = []
        keyDown.keyboardSetUnicodeString(stringLength: length, unicodeString: unicode)
        keyUp.keyboardSetUnicodeString(stringLength: length, unicodeString: unicode)
        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: unicodeEventInterval)
        keyUp.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: unicodeEventInterval)
    }

    /// Physical Return key (virtual key 0x24).
    private nonisolated static func postReturn(source: CGEventSource?) throws {
        let returnKey: CGKeyCode = 0x24
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: returnKey, keyDown: false) else {
            throw KeystrokeError.eventCreationFailed
        }
        keyDown.flags = []
        keyUp.flags = []
        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.012)
        keyUp.post(tap: .cghidEventTap)
    }
}
