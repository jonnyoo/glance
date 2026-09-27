import Foundation

@main struct TriggerSelfTest {
    @MainActor static func main() async {
        var event = 1
        var armed = false
        var locked = true
        var evaluations = 0
        var delays = 0
        func attempt() { evaluations += 1; if locked { armed = true } }

        // A confirmed lock starts immediately, with no delayed work that could
        // wake up after the two-second debounce and restart the same scan.
        await LockTriggerRetry.evaluate(event: event, currentEvent: { event }, isArmed: { armed }, attempt: attempt, settle: {
            delays += 1
        })
        precondition(armed && evaluations == 1 && delays == 0)

        // Regression: unlock notification arrives while CGSession still says
        // locked. Stop/reset immediately despite the prior scan being armed,
        // so a rapid second lock starts a fresh scan. Negative hints can stop
        // work but cannot grant any authorization, even if spoofed.
        evaluations = 0
        var stops = 0
        await LockTriggerRetry.evaluate(event: event, currentEvent: { event }, isArmed: { armed }, attempt: attempt,
            stopRequested: true, stop: { stops += 1; armed = false }, settle: {
                delays += 1
            })
        precondition(!armed && stops == 1 && evaluations == 0 && delays == 0)
        event += 1
        await LockTriggerRetry.evaluate(event: event, currentEvent: { event }, isArmed: { armed }, attempt: attempt, settle: {})
        precondition(armed && evaluations == 1)

        // Sleep interrupts warmup too; it never consumes the next wake's scan.
        evaluations = 0
        await LockTriggerRetry.evaluate(event: event, currentEvent: { event }, isArmed: { armed }, attempt: attempt,
            stopRequested: true, stop: { stops += 1; armed = false }, settle: {})
        precondition(!armed && stops == 2 && evaluations == 0)

        // CGSession can settle late. A refused first arm must remain eligible.
        armed = false; locked = false; evaluations = 0
        await LockTriggerRetry.evaluate(event: event, currentEvent: { event }, isArmed: { armed }, attempt: attempt, settle: {
            delays += 1; locked = true
        })
        precondition(armed && evaluations == 2 && delays == 1)

        // A newer event owns its own trigger; the old retry must not consume it.
        armed = false; locked = false; evaluations = 0
        await LockTriggerRetry.evaluate(event: event, currentEvent: { event }, isArmed: { armed }, attempt: attempt, settle: {
            event += 1; locked = true
        })
        precondition(!armed && evaluations == 1)

        // A separate handler can arm during the settling interval.
        locked = false; evaluations = 0
        await LockTriggerRetry.evaluate(event: event, currentEvent: { event }, isArmed: { armed }, attempt: attempt, settle: {
            armed = true; locked = true
        })
        precondition(evaluations == 1)

        // Missing lock confirmation never arms; there is only one retry.
        armed = false; locked = false; evaluations = 0
        await LockTriggerRetry.evaluate(event: event, currentEvent: { event }, isArmed: { armed }, attempt: attempt, settle: {})
        precondition(!armed && evaluations == 2)

        // Cancellation during the wait prevents the second attempt.
        evaluations = 0
        var pending: Task<Void, Never>?
        pending = Task { @MainActor in
            await LockTriggerRetry.evaluate(event: event, currentEvent: { event }, isArmed: { armed }, attempt: attempt, settle: {
                pending?.cancel(); locked = true
            })
        }
        await pending?.value
        precondition(!armed && evaluations == 1)
        print("Trigger tests passed: immediate arm, settling retry, rapid lock/unlock/relock, sleep, supersession, one-shot behavior and cancellation.")
    }
}
