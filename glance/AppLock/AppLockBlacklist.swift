//
//  AppLockBlacklist.swift
//  glance
//
//  Contains the blacklist of apps that cannot be locked.
//

import Foundation

/// Contains the blacklist of apps that cannot be locked to prevent system lockout or locking critical developer tools.
public enum AppLockBlacklist {
    /// Set of bundle identifiers that are blacklisted from being locked.
    public static let bundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.apple.finder",
        "com.apple.SystemSettings",
        "com.apple.systempreferences",
        "com.apple.ActivityMonitor",
        "com.apple.dt.Xcode",
        "com.microsoft.VSCode"
    ]
    
    /// Checks if a bundle ID is protected (i.e., blacklisted) from being locked.
    /// Also protects the app's own bundle ID.
    public static func isProtected(_ bundleID: String, ownBundleID: String? = Bundle.main.bundleIdentifier) -> Bool {
        if bundleID == ownBundleID {
            return true
        }
        return bundleIDs.contains(bundleID)
    }
}
