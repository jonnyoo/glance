//
//  LockMonitor.swift
//  glance
//
//  Detects macOS lock/unlock state for the CGEvent injection POC.
//

import Foundation
import AppKit
import CoreGraphics
import Observation

/// Which signal most recently fired. `withObservationTracking`'s `onChange`
/// doesn't say *which* tracked property changed, so observers that need to
/// tell "the screen just locked" from "the Mac woke up" read this alongside
/// the monotonic `eventCount`.
enum LockEventKind {
    case screenLocked
    case screenUnlocked
    case willSleep
    /// The display turned back on — whether from true system sleep, from
    /// display-only sleep, or from the screensaver stopping at an
    /// already-locked screen.
    ///
    /// This used to be split into two kinds (`.systemWake`, gated on a prior
    /// `willSleepNotification`, vs. `.userActivity` for everything else) so
    /// "On wake" and "On activity" could be separate trigger options. In
    /// practice that split was unreliable: `willSleepNotification` only
    /// fires for whole-system sleep, not the far more common case of the
    /// *display* sleeping on its own idle timer while the system stays
    /// awake — so most real "the Mac woke up" moments were silently
    /// misclassified as `.userActivity`, and "On wake" alone effectively
    /// never fired. The two are merged into this one case.
    case wake
}

@Observable
final class LockMonitor {
    /// Cheap, notification-derived flag. NOT trustworthy on its own: any
    /// same-user process can post `com.apple.screenIsLocked` /
    /// `com.apple.screenIsUnlocked` — there's no sender-authenticity check.
    /// It's also unreliable across sleep: if the Mac sleeps (e.g. lid close)
    /// around the same moment the screen locks, this process can be
    /// suspended before the notification is delivered, so the flag never
    /// flips. Use for UI display and as a cheap trigger signal only — never
    /// as the sole gate for a security-sensitive action.
    private(set) var isScreenLocked: Bool = false

    /// Increments on every wake signal (display or system wake, including
    /// lid open). This is the trigger that catches the case above: the lock
    /// may have already happened while we were suspended, so wake is the
    /// first chance we get to notice — callers should re-derive lock state
    /// via `isScreenActuallyLocked()` whenever this changes, rather than
    /// trusting `isScreenLocked` to have been updated.
    private(set) var wakeEventCount: Int = 0

    /// True from `willSleepNotification` until the next wake notification.
    /// `screenIsLocked` fires ~150ms *before* the system actually finishes
    /// suspending (confirmed via `pmset -g log` + `os_log` correlation), so a
    /// naive "screen just locked" trigger fires too early in a sleep cycle —
    /// it races the imminent suspend and can hit a login window that's about
    /// to be torn down. Callers should use this to skip acting on a lock
    /// event while a sleep is in flight, and instead wait for the wake
    /// trigger (`wakeEventCount`) once this flips back to false.
    private(set) var isSleeping: Bool = false

    /// The most recent signal, and a counter that increments with it.
    /// Observers track `eventCount` (it changes on *every* event, including
    /// two of the same kind in a row, which `lastEvent` alone wouldn't
    /// register) and then read `lastEvent` to decide what happened.
    private(set) var lastEvent: LockEventKind?
    private(set) var eventCount: Int = 0

    private var distributedObservers: [NSObjectProtocol] = []
    private var workspaceObservers: [NSObjectProtocol] = []

    init() {
        startMonitoring()
    }

    deinit {
        let distributed = DistributedNotificationCenter.default()
        for observer in distributedObservers {
            distributed.removeObserver(observer)
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            workspace.removeObserver(observer)
        }
    }

    private func startMonitoring() {
        let distributed = DistributedNotificationCenter.default()
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isScreenLocked = true
            self?.record(.screenLocked)
        })
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isScreenLocked = false
            self?.record(.screenUnlocked)
        })
        // The user dismissing the screensaver is the clearest "I want back
        // in" signal available. Observing the *key press* that did it isn't
        // possible — the lock screen runs under Secure Event Input, which
        // suppresses keyboard event taps regardless of Accessibility trust —
        // so this notification stands in for it.
        distributedObservers.append(distributed.addObserver(
            forName: Notification.Name("com.apple.screensaver.didstop"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.record(.wake)
        })

        let workspace = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.isSleeping = true
            self?.record(.willSleep)
        })
        // Both display-level and system-level wake are observed and treated
        // as equivalent triggers: in testing they land within ~100ms of each
        // other but in either order, so reacting to whichever arrives first
        // gives the fastest, most robust wake detection.
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recordWake()
        })
        workspaceObservers.append(workspace.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recordWake()
        })
    }

    private func recordWake() {
        isSleeping = false
        wakeEventCount += 1
        record(.wake)
    }

    private func record(_ kind: LockEventKind) {
        lastEvent = kind
        eventCount += 1
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
