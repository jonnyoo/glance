//
//  DisplayMath.swift
//  glance
//
//  The display decisions that don't need a live NSScreen. Kept free of AppKit so
//  tools/display_selftest.swift can compile this file on its own.
//

import CoreGraphics

enum DisplayMath {
    /// The value saved for a display choice: CoreGraphics' per-display UUID, which survives
    /// reboots and dock replugs, or the raw `CGDirectDisplayID` when no UUID is available.
    /// The raw number is handed out per session, so on its own it can name a different
    /// monitor (or none) after the next reconfiguration.
    static func persistentID(uuid: String?, number: CGDirectDisplayID) -> String {
        uuid ?? String(number)
    }

    /// Whether a saved display id names this display. The raw number is still accepted
    /// because that's what every choice saved before UUIDs holds; see
    /// `NotchGeometry.preferredScreen()` for the rewrite that retires it. UUIDs compare
    /// case-insensitively, as UUIDs do. The display picker and the camera override both
    /// match through here, so a pin can't be honoured by one and ignored by the other.
    static func savedID(_ saved: String, matchesUUID uuid: String?, number: CGDirectDisplayID) -> Bool {
        if let uuid, saved.uppercased() == uuid.uppercased() { return true }
        return saved == String(number)
    }

    /// Stand-in for a reading that can't be a real notch. 185pt is what a 14" MacBook Pro
    /// measures at default scaling, so a bad reading lands close to real hardware.
    static let fallbackNotchWidth: CGFloat = 185

    /// Real notches measure roughly 150-200pt across models and display scalings, so
    /// anything under this is a broken reading, not a small notch.
    static let minimumPlausibleNotchWidth: CGFloat = 120

    /// A physical notch's width: the gap the menu-bar areas either side of it leave.
    /// Real readings are used as they are, never floored, or the silhouette comes out
    /// wider than the notch. Only a missing area or an implausible result falls back:
    /// a missing area read as 0 would otherwise make the "notch" the whole screen, and
    /// `arm()` can catch the areas mid-layout around wake (re-measured on disarm/collapse).
    static func notchWidth(screenWidth: CGFloat, leftAreaWidth: CGFloat?, rightAreaWidth: CGFloat?) -> CGFloat {
        guard let leftAreaWidth, let rightAreaWidth else { return fallbackNotchWidth }
        let measured = screenWidth - leftAreaWidth - rightAreaWidth
        guard measured >= minimumPlausibleNotchWidth, measured < screenWidth / 2 else { return fallbackNotchWidth }
        return measured
    }
}
