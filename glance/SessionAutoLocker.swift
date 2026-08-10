//
//  SessionAutoLocker.swift
//  glance
//
//  Enforces `GlanceSettings.autoLockInterval`: re-locks the Touch-ID-gated
//  session once it has sat unused for longer than the user's chosen limit.
//
//  Before this existed, `SecureCredentialManager.lockSession()` had exactly
//  one caller — a manual toggle in the old debug window — so in practice the
//  unwrapped AES session key stayed cached in memory for the entire lifetime
//  of the process. That lifetime is not short: the app deliberately outlives
//  its last window (`applicationShouldTerminateAfterLastWindowClosed`
//  returns false) so it can still react to the screen locking, so "until
//  quit" could easily mean weeks.
//

import Foundation
import AppKit

@MainActor
final class SessionAutoLocker {
    private let pocController: POCController
    private var timer: Timer?

    /// Coarse on purpose. The shortest selectable limit is a full day, so
    /// checking every few minutes is already far finer-grained than needed;
    /// polling faster would only burn wakeups. The exact firing moment
    /// doesn't matter because the decision is made by comparing timestamps,
    /// not by counting ticks — see `evaluate()`.
    private let checkInterval: TimeInterval = 5 * 60

    init(pocController: POCController) {
        self.pocController = pocController
        // `.common` so the countdown keeps being checked during tracking
        // runloop modes (an open menu, a drag) rather than stalling.
        let timer = Timer(timeInterval: checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        // Also evaluate on wake: the Mac may have been asleep past the
        // deadline, during which no timer fires at all. Comparing stored
        // timestamps means the elapsed sleep still counts as idle time, but
        // something has to prompt the comparison once we're awake again.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.evaluate() }
        }

        evaluate()
    }

    deinit {
        timer?.invalidate()
    }

    /// Locks the session if it has been idle past the configured limit.
    ///
    /// Routed through `POCController.lockSession()` rather than calling
    /// `SecureCredentialManager.lockSession()` directly — the latter would
    /// leave `POCController.isSessionUnlocked` (the `@Observable` flag the
    /// Settings UI actually renders from) stale, so the Password page would
    /// keep showing an unlocked state for a session that no longer exists.
    func evaluate() {
        guard SecureCredentialManager.isSessionUnlocked,
              let lastActivityAt = SecureCredentialManager.lastActivityAt
        else { return }

        let idleLimit = GlanceSettings.shared.autoLockInterval.duration
        guard Date().timeIntervalSince(lastActivityAt) >= idleLimit else { return }

        pocController.lockSession()
    }
}
