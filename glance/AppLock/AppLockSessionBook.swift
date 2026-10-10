//
//  AppLockSessionBook.swift
//  glance
//
//  Tracks active unlock sessions for applications.
//

import Foundation

/// In-memory tracker for unlocked application sessions.
@MainActor
public final class AppLockSessionBook {
    private struct Session {
        let policy: RelockPolicy
        let grantedAt: TimeInterval // Monotonic system uptime
        var focusLostAt: TimeInterval? // Monotonic system uptime when focus was lost
    }
    
    // Volatile storage of active sessions
    private var sessions: [String: Session] = [:]
    
    public init() {}
    
    /// Monotonic clock for time tracking (prevents time-change bypass)
    private var currentUptime: TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }
    
    /// Grants an unlock session for the specified app.
    public func grant(_ bundleID: String, policy: RelockPolicy) {
        sessions[bundleID] = Session(policy: policy, grantedAt: currentUptime, focusLostAt: nil)
    }
    
    /// Checks if a session is still valid according to its policy.
    public func isUnlocked(_ bundleID: String) -> Bool {
        guard let session = sessions[bundleID] else {
            return false
        }
        
        let now = currentUptime
        
        switch session.policy {
        case .everyTime:
            // If focus was lost at all, it's locked.
            return session.focusLostAt == nil
            
        case .afterMinutes(let minutes):
            let seconds = TimeInterval(minutes * 60)
            return (now - session.grantedAt) < seconds
            
        case .afterFocusLossMinutes(let minutes):
            if let lostAt = session.focusLostAt {
                let seconds = TimeInterval(minutes * 60)
                return (now - lostAt) < seconds
            }
            return true
        }
    }
    
    /// Called when any app becomes active.
    /// Any unlocked app other than the active one has lost focus and was switched away from!
    public func appActivated(_ activeBundleID: String) {
        for (bundleID, session) in sessions {
            guard bundleID != activeBundleID else { continue }
            switch session.policy {
            case .everyTime:
                // Immediately revoke session when switching away
                sessions.removeValue(forKey: bundleID)
            case .afterMinutes:
                break
            case .afterFocusLossMinutes:
                if session.focusLostAt == nil {
                    var s = session
                    s.focusLostAt = currentUptime
                    sessions[bundleID] = s
                }
            }
        }
    }
    
    /// Records when a locked app loses focus (e.g. minimized, deactivated, hidden).
    public func focusLost(_ bundleID: String) {
        guard let session = sessions[bundleID] else { return }
        switch session.policy {
        case .everyTime:
            // Immediately revoke session when minimized or focus lost
            sessions.removeValue(forKey: bundleID)
        case .afterFocusLossMinutes:
            if session.focusLostAt == nil {
                var s = session
                s.focusLostAt = currentUptime
                sessions[bundleID] = s
            }
        case .afterMinutes:
            break
        }
    }
    
    /// Records when a locked app gains focus.
    public func focusGained(_ bundleID: String) {
        guard var session = sessions[bundleID] else { return }
        
        if isUnlocked(bundleID) {
            switch session.policy {
            case .afterFocusLossMinutes:
                // Returning resets the focus loss timer
                session.focusLostAt = nil
                sessions[bundleID] = session
            case .everyTime, .afterMinutes:
                break
            }
        } else {
            revoke(bundleID)
        }
    }
    
    /// Clears all active sessions (e.g., used on system sleep or screen lock).
    public func revokeAll() {
        sessions.removeAll()
    }
    
    /// Revokes the session for a specific app immediately.
    public func revoke(_ bundleID: String) {
        sessions.removeValue(forKey: bundleID)
    }
}
