//
//  LockedAppStore.swift
//  glance
//
//  Manages the persistence and state of locked apps.
//

import Foundation
import SwiftUI

/// Represents an app that is configured to be locked.
public struct LockedApp: Codable, Equatable, Sendable, Identifiable {
    public var id: String { bundleID }
    public let bundleID: String
    public let name: String
    public var policy: RelockPolicy
    
    public init(bundleID: String, name: String, policy: RelockPolicy) {
        self.bundleID = bundleID
        self.name = name
        self.policy = policy
    }
}

/// Store for managing the list of locked apps and the master toggle.
@Observable @MainActor
public final class LockedAppStore {
    public static let shared = LockedAppStore()
    
    private let defaults = UserDefaults.standard
    private let appsKey = "appLock.apps"
    private let enabledKey = "appLock.enabled"
    
    /// Master toggle for the app lock feature.
    public var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: enabledKey)
        }
    }
    
    /// List of all apps currently configured to be locked.
    public var apps: [LockedApp] {
        didSet {
            saveApps()
        }
    }
    
    private init() {
        self.isEnabled = defaults.bool(forKey: enabledKey)
        
        if let data = defaults.data(forKey: appsKey),
           let decoded = try? JSONDecoder().decode([LockedApp].self, from: data) {
            self.apps = decoded
        } else {
            self.apps = []
        }
    }
    
    private func saveApps() {
        if let encoded = try? JSONEncoder().encode(apps) {
            defaults.set(encoded, forKey: appsKey)
        }
    }
    
    /// Adds a new app to the locked list.
    public func add(_ app: LockedApp) {
        if !apps.contains(where: { $0.bundleID == app.bundleID }) {
            apps.append(app)
        }
    }
    
    /// Removes an app from the locked list by its bundle identifier.
    public func remove(bundleID: String) {
        apps.removeAll { $0.bundleID == bundleID }
    }
    
    /// Checks if a given bundle identifier is currently in the locked list.
    public func isLocked(_ bundleID: String) -> Bool {
        let cleanID = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        return apps.contains {
            $0.bundleID.caseInsensitiveCompare(cleanID) == .orderedSame ||
            cleanID.hasPrefix($0.bundleID)
        }
    }
    
    /// Updates the relock policy for a specific app.
    public func updatePolicy(for bundleID: String, to policy: RelockPolicy) {
        if let index = apps.firstIndex(where: { $0.bundleID == bundleID }) {
            apps[index].policy = policy
        }
    }
}
