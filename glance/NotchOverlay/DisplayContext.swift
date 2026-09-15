import AppKit

/// Classifies the current display topology of the Mac as observed from
/// `NSScreen.screens`, used to decide where the notched panel should anchor itself.
///
/// The cases are derived from the built-in vs. external split that
/// `NSScreen.isBuiltIn` exposes (see `NotchGeometry.swift`):
///
/// - `builtInOnly`: the built-in display is present and no external is connected.
/// - `builtInAndExternal`: the built-in display is present alongside at least one external.
/// - `externalOnly`: no built-in display is present and at least one external is connected.
enum DisplayContext {
    case builtInOnly
    case builtInAndExternal
    case externalOnly

    /// Computes the current context from `NSScreen.screens`.
    ///
    /// A Mac always reports at least one screen; when none are present (which should
    /// not happen in practice) it falls back to `builtInOnly`.
    static func current() -> DisplayContext {
        let screens = NSScreen.screens
        let hasBuiltIn = screens.contains { $0.isBuiltIn }
        let hasExternal = screens.contains { !$0.isBuiltIn }

        if hasBuiltIn {
            return hasExternal ? .builtInAndExternal : .builtInOnly
        }
        return hasExternal ? .externalOnly : .builtInOnly
    }
}
