//
//  LockMonitor.swift
//  glance
//
//  Detects macOS lock/unlock state for the CGEvent injection POC.
//

import Foundation
import CoreGraphics
import Observation

@Observable
final class LockMonitor {
    /// Cheap, notification-derived flag. NOT trustworthy on its own: any
    /// same-user process can post `com.apple.screenIsLocked` /
    /// `com.apple.screenIsUnlocked` — there's no sender-authenticity check.
    /// Use for UI display and as a trigger signal only.
    private(set) var isScreenLocked: Bool = false

    private var observers: [NSObjectProtocol] = []

    init() {
        startMonitoring()
    }

    deinit {
        let center = DistributedNotificationCenter.default()
        for observer in observers {
            center.removeObserver(observer)
        }
    }

    private func startMonitoring() {
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isScreenLocked = true
        })
        observers.append(center.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isScreenLocked = false
        })
    }

    /// Authoritative lock state, queried directly from the CoreGraphics session
    /// server instead of derived from a spoofable distributed notification.
    /// Returns `false` (fail-closed) if the session dictionary is unavailable.
    nonisolated static func isScreenActuallyLocked() -> Bool {
        guard let dict = CGSessionCopyCurrentDictionary() as? [String: Any] else {
            return false
        }
        return (dict["CGSSessionScreenIsLocked"] as? Bool) ?? false
    }
}
