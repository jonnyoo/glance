//
//  AppLockState.swift
//  glance
//
//  Which locked apps the user has already opened, and whether bringing one to the front again needs a fresh check.
//  Pure value logic with no AppKit, so tools/app_lock_selftest.swift can exercise it offline.
//

import Foundation

/// When an app the user opened locks again. The Mac locking or sleeping relocks every app regardless.
nonisolated enum AppLockRelockPolicy: String, CaseIterable, Identifiable, Sendable {
    case onQuit
    case afterFiveMinutesAway
    case everyActivation

    var id: String { rawValue }
}

nonisolated struct AppLockState: Sendable {
    /// `afterFiveMinutesAway`'s limit.
    static let awayLimit: TimeInterval = 5 * 60
    /// Activations this soon after an unlock are the app returning to the front because of that unlock, not the user coming back.
    static let reactivationGrace: TimeInterval = 2

    private struct Unlock: Sendable {
        var pid: Int32
        var unlockedAt: Date
        var deactivatedAt: Date?
    }

    private var unlocks: [String: Unlock] = [:]

    init() {}

    /// Whether an app coming to the front is something App Lock should react to at all. Background agents — the Touch ID /
    /// password sheet (`coreautha`), menu bar utilities, launchers — aren't the user switching apps, so they must neither
    /// cancel a pending check nor be locked themselves. Glance is skipped too.
    static func reactsToActivation(bundleID: String?, isRegularApp: Bool, ownBundleID: String?) -> Bool {
        guard let bundleID, isRegularApp else { return false }
        return bundleID != ownBundleID
    }

    func needsVerification(bundleID: String, pid: Int32, policy: AppLockRelockPolicy, now: Date) -> Bool {
        guard let unlock = unlocks[bundleID], unlock.pid == pid else { return true }
        if now.timeIntervalSince(unlock.unlockedAt) < Self.reactivationGrace { return false }
        switch policy {
        case .onQuit:
            return false
        case .afterFiveMinutesAway:
            guard let away = unlock.deactivatedAt else { return false }
            return now.timeIntervalSince(away) > Self.awayLimit
        case .everyActivation:
            return true
        }
    }

    mutating func markUnlocked(bundleID: String, pid: Int32, at now: Date) {
        unlocks[bundleID] = Unlock(pid: pid, unlockedAt: now, deactivatedAt: nil)
    }

    /// The app came back without needing a check, so its away timer starts over.
    mutating func markActivated(bundleID: String, pid: Int32) {
        guard unlocks[bundleID]?.pid == pid else { return }
        unlocks[bundleID]?.deactivatedAt = nil
    }

    /// Only the first deactivation counts; a later one must not push the away timer back.
    mutating func markDeactivated(bundleID: String, pid: Int32, at now: Date) {
        guard unlocks[bundleID]?.pid == pid, unlocks[bundleID]?.deactivatedAt == nil else { return }
        unlocks[bundleID]?.deactivatedAt = now
    }

    mutating func markTerminated(bundleID: String) {
        unlocks[bundleID] = nil
    }

    mutating func lockAll() {
        unlocks.removeAll()
    }
}
