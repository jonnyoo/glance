//
//  GlobalHotKey.swift
//  glance
//
//  System-wide shortcut via Carbon's `RegisterEventHotKey` — needs no permission, but like any
//  user-session hotkey it can't fire on the lock screen (loginwindow owns the keyboard there).
//

import AppKit
import Carbon.HIToolbox

/// A recorded key + modifier combo. `key` is the label captured at record time, so the UI never
/// has to translate a virtual key code back through the current keyboard layout.
struct HotKeyShortcut: Codable, Equatable {
    let keyCode: UInt32
    /// `NSEvent.ModifierFlags` raw value, limited to ⌃⌥⇧⌘.
    let modifiers: UInt
    let key: String

    /// ⌃⌥⌘F — "F" for face; rarely bound by apps.
    static let defaultToggleFaceUnlock = HotKeyShortcut(
        keyCode: UInt32(kVK_ANSI_F),
        modifiers: NSEvent.ModifierFlags([.control, .option, .command]).rawValue,
        key: "F"
    )

    private static let symbols: [(NSEvent.ModifierFlags, String, Int)] = [
        (.control, "⌃", controlKey), (.option, "⌥", optionKey), (.shift, "⇧", shiftKey), (.command, "⌘", cmdKey),
    ]

    private var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var displayString: String {
        Self.symbols.filter { flags.contains($0.0) }.map(\.1).joined() + key
    }

    var carbonModifiers: UInt32 {
        Self.symbols.filter { flags.contains($0.0) }.reduce(0) { $0 | UInt32($1.2) }
    }
}

extension HotKeyShortcut {
    /// nil unless ⌘, ⌃ or ⌥ is held — a bare or shift-only key would swallow normal typing system-wide.
    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.control, .option, .shift, .command])
        guard !flags.isDisjoint(with: [.control, .option, .command]) else { return nil }
        self.init(
            keyCode: UInt32(event.keyCode),
            modifiers: flags.rawValue,
            key: Self.specialKeyLabels[Int(event.keyCode)]
                ?? event.charactersIgnoringModifiers?.uppercased() ?? "?"
        )
    }

    /// Keys whose `charactersIgnoringModifiers` is whitespace or a private-use glyph.
    private static let specialKeyLabels: [Int: String] = [
        kVK_Space: "Space", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6",
        kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
    ]
}

/// Owns one registered hotkey. Call `register` again to change it, or with `nil` to remove it.
final class GlobalHotKey {
    var onPress: (() -> Void)?

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?

    /// False when the system refused the combo — usually because another app already registered it.
    @discardableResult
    func register(_ shortcut: HotKeyShortcut?) -> Bool {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        guard let shortcut else { return true }
        installHandlerIfNeeded()
        let status = RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            EventHotKeyID(signature: OSType(0x676C_6E63), id: 1), // 'glnc'
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        return status == noErr
    }

    /// Capture-less C callback; `self` threaded through the context pointer. `passUnretained` is safe since
    /// the owner (`FaceUnlockCoordinator`) lives for the whole app lifetime.
    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            // Delivered on the main thread; hop onto the main actor to satisfy isolation.
            Task { @MainActor in hotKey.onPress?() }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }
}
