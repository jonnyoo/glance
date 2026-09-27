import Foundation

/// Evaluate immediately, then allow one settling retry only for an unhandled
/// event. An already-armed wake must never become a second scan if the retry
/// continuation is delayed beyond the wake debounce window.
@MainActor enum LockTriggerRetry {
    static func evaluate(event: Int, currentEvent: () -> Int, isArmed: () -> Bool,
                         attempt: () -> Void,
                         stopRequested: Bool = false, stop: () -> Void = {},
                         settle: () async -> Void = {
                             try? await Task.sleep(for: .milliseconds(300))
                         }) async {
        guard !Task.isCancelled else { return }
        // Unlock/sleep notifications may lead CGSession's state change. They
        // are safe cancellation hints, never authorization to start a scan.
        // Handle them even if the preceding lock has already armed a scan.
        if stopRequested { stop(); return }
        attempt()
        guard !isArmed() else { return }
        await settle()
        guard !Task.isCancelled, currentEvent() == event, !isArmed() else { return }
        attempt()
    }
}
