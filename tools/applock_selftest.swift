//
//  applock_selftest.swift
//  glance (tools)
//
//  Offline test for App Lock's decision core. Like `liveness_selftest.swift`, this project has no test target, so it
//  compiles as a standalone script against the real file:
//
//      swiftc -O -o /tmp/applock_selftest \
//        glance/AppLock/AppLockEngine.swift \
//        tools/applock_selftest.swift \
//      && /tmp/applock_selftest
//
//  `AppLockEngine` is the only App Lock file included on purpose: everything else (the curtain window, the camera
//  scan, hiding and reopening real apps) is the coordinator carrying out the effects asserted here, and needs a
//  running Mac session to exercise.
//
//  What this pins down is the behaviour a locked app must never drift away from: it is challenged every time it
//  comes forward, it is put out of sight the moment the user leaves it, and nothing that finishes late — a scan,
//  a Touch ID prompt — can unlock an app the user has already moved on from.
//

import Foundation

private typealias Engine = AppLockEngine
private typealias App = AppLockEngine.App

private let notes = App(pid: 100, bundleID: "com.example.notes", isRegular: true)
private let chat = App(pid: 200, bundleID: "com.example.chat", isRegular: true)
private let browser = App(pid: 300, bundleID: "com.example.browser", isRegular: true)
/// A menu bar utility / system auth dialog: comes forward without the user having left anything.
private let agent = App(pid: 400, bundleID: "com.example.agent", isRegular: false)

private let start = Date(timeIntervalSince1970: 1_000_000)

/// `notes` and `chat` locked, `browser` and `agent` not.
private func makeEngine() -> Engine {
    var engine = Engine()
    _ = engine.configure(isEnabled: true, lockedBundleIDs: [notes.bundleID, chat.bundleID])
    return engine
}

/// Activates `app` and hands back the challenge that must have been raised for it.
private func challenge(_ app: App, in engine: inout Engine, at now: Date = start) -> Engine.Challenge {
    let effects = engine.appActivated(app, at: now)
    guard case .raiseCurtain(let raised)? = effects.last, raised.app == app else {
        fatalError("FAIL: activating locked \(app.bundleID) should raise the curtain, got \(effects).")
    }
    return raised
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
    print("PASS: \(message)")
}

@main
struct AppLockSelfTest {
    static func main() {
        runChallengeTests()
        runRelockTests()
        runSystemPromptTests()
        runStaleResultTests()
        runLifecycleTests()
        runReconcileTests()
        runConfigurationTests()
        print("\nAll App Lock engine checks passed.")
    }

    // MARK: - Being challenged

    private static func runChallengeTests() {
        var idle = Engine()
        expect(idle.appActivated(notes, at: start).isEmpty, "an engine that was never configured does nothing")

        var engine = makeEngine()
        expect(engine.appActivated(browser, at: start).isEmpty, "an app that isn't locked comes forward untouched")

        let first = challenge(notes, in: &engine)
        expect(engine.challenge == first && first.phase == .curtain, "a locked app coming forward is covered")
        expect(engine.unlocked == nil, "being covered is not being unlocked")
        expect(engine.appActivated(notes, at: start).isEmpty, "the covered app re-activating doesn't stack a second challenge")

        expect(
            engine.passed(challengeID: first.id) == [.lowerCurtain(notes, .unlocked)],
            "a face match uncovers the app where it stands"
        )
        expect(engine.unlocked == notes && engine.challenge == nil, "…and leaves it unlocked")
        expect(engine.appActivated(notes, at: start).isEmpty, "an unlocked app re-activating isn't challenged again")

        var cancelled = makeEngine()
        let pending = challenge(notes, in: &cancelled)
        expect(
            cancelled.cancel(challengeID: pending.id) == [.lowerCurtain(notes, .cancelled)],
            "cancelling puts the app out of sight before the curtain goes"
        )
        expect(cancelled.unlocked == nil && cancelled.challenge == nil, "…and unlocks nothing")
    }

    // MARK: - Leaving an app

    private static func runRelockTests() {
        var engine = makeEngine()
        let first = challenge(notes, in: &engine)
        _ = engine.passed(challengeID: first.id)

        expect(engine.appActivated(agent, at: start).isEmpty, "an agent coming forward doesn't relock the app in use")
        expect(engine.unlocked == notes, "…it stays unlocked")

        expect(engine.appActivated(browser, at: start) == [.hide(notes)], "switching to another app hides the locked one")
        expect(engine.unlocked == nil, "…and relocks it")

        let again = challenge(notes, in: &engine)
        expect(again.id != first.id, "coming back is a fresh challenge — every time, not once per launch")

        // Straight from one locked app to another: the first is put away, the second is covered.
        _ = engine.passed(challengeID: again.id)
        expect(
            engine.appActivated(chat, at: start).prefix(1) == [.hide(notes)] && engine.challenge?.app == chat,
            "going from one locked app to another relocks the first and challenges the second"
        )

        var covered = makeEngine()
        _ = challenge(notes, in: &covered)
        expect(covered.appActivated(agent, at: start).isEmpty, "an agent coming forward leaves the curtain up")
        expect(
            covered.appActivated(browser, at: start) == [.lowerCurtain(notes, .cancelled)],
            "switching away mid-challenge cancels it"
        )

        var swapped = makeEngine()
        _ = challenge(notes, in: &swapped)
        let effects = swapped.appActivated(chat, at: start)
        expect(
            effects.first == .lowerCurtain(notes, .cancelled) && swapped.challenge?.app == chat,
            "another locked app coming forward mid-challenge takes the curtain over"
        )

        var hidden = makeEngine()
        let shown = challenge(notes, in: &hidden)
        _ = hidden.passed(challengeID: shown.id)
        expect(hidden.appHidden(pid: notes.pid).isEmpty && hidden.unlocked == nil, "hiding an unlocked app relocks it")
        _ = challenge(notes, in: &hidden)
        expect(
            hidden.appHidden(pid: notes.pid) == [.lowerCurtain(notes, .abandoned)],
            "the covered app hiding itself drops the curtain"
        )
    }

    // MARK: - Touch ID / password fallback

    private static func runSystemPromptTests() {
        var engine = makeEngine()
        let first = challenge(notes, in: &engine)
        let prompt = Engine.Challenge(id: first.id, app: notes, phase: .systemPrompt)
        expect(
            engine.systemPromptRequested(challengeID: first.id) == [.presentSystemPrompt(prompt)],
            "asking for Touch ID hands the challenge to the system prompt"
        )
        expect(engine.appActivated(browser, at: start).isEmpty, "the app being hidden for the prompt cancels nothing")
        expect(engine.challenge == prompt, "…the prompt is still pending")
        expect(
            engine.appActivated(notes, at: start) == [.hide(notes)],
            "bringing the app forward behind the prompt hides it again"
        )
        expect(
            engine.passed(challengeID: first.id).isEmpty,
            "a face match can't resolve a challenge that has moved to the system prompt"
        )

        expect(
            engine.systemPromptFinished(challengeID: first.id, success: true, at: start) == [.reopen(notes)],
            "a successful prompt reopens the app"
        )
        expect(engine.unlocked == nil, "…which isn't unlocked until it actually comes forward")
        expect(
            engine.appActivated(notes, at: start.addingTimeInterval(1)).isEmpty && engine.unlocked == notes,
            "the reopen is let through without a second challenge"
        )

        // The grant is single use: leave and come back, and it's a challenge again.
        _ = engine.appActivated(browser, at: start.addingTimeInterval(2))
        _ = challenge(notes, in: &engine, at: start.addingTimeInterval(3))

        var expired = makeEngine()
        let late = challenge(notes, in: &expired)
        _ = expired.systemPromptRequested(challengeID: late.id)
        _ = expired.systemPromptFinished(challengeID: late.id, success: true, at: start)
        _ = challenge(notes, in: &expired, at: start.addingTimeInterval(Engine.grantLifetime + 1))
        expect(expired.unlocked == nil, "a prompt success that's never collected expires")

        // A relaunched app has a new pid; the grant follows the bundle so the reopen still counts.
        var relaunched = makeEngine()
        let old = challenge(notes, in: &relaunched)
        _ = relaunched.systemPromptRequested(challengeID: old.id)
        _ = relaunched.systemPromptFinished(challengeID: old.id, success: true, at: start)
        let reborn = App(pid: 101, bundleID: notes.bundleID, isRegular: true)
        expect(
            relaunched.appActivated(reborn, at: start).isEmpty && relaunched.unlocked == reborn,
            "a prompt success survives the app relaunching under a new pid"
        )

        var failed = makeEngine()
        let denied = challenge(notes, in: &failed)
        _ = failed.systemPromptRequested(challengeID: denied.id)
        expect(
            failed.systemPromptFinished(challengeID: denied.id, success: false, at: start).isEmpty,
            "a failed or cancelled prompt reopens nothing"
        )
        _ = challenge(notes, in: &failed)
        expect(failed.unlocked == nil, "…and the app is challenged like any other time")

        var superseded = makeEngine()
        let waiting = challenge(notes, in: &superseded)
        _ = superseded.systemPromptRequested(challengeID: waiting.id)
        let effects = superseded.appActivated(chat, at: start)
        expect(
            effects.first == .cancelSystemPrompt && superseded.challenge?.app == chat,
            "another locked app coming forward dismisses a pending prompt and is covered itself"
        )
        expect(
            superseded.systemPromptFinished(challengeID: waiting.id, success: true, at: start).isEmpty,
            "…and the dismissed prompt can no longer unlock anything"
        )
    }

    // MARK: - Late results

    private static func runStaleResultTests() {
        var engine = makeEngine()
        let first = challenge(notes, in: &engine)
        _ = engine.appActivated(browser, at: start)
        expect(engine.passed(challengeID: first.id).isEmpty, "a scan that finishes after the user left unlocks nothing")
        expect(engine.cancel(challengeID: first.id).isEmpty, "…and neither does a late cancel")
        expect(engine.systemPromptRequested(challengeID: first.id).isEmpty, "…or a late request for the system prompt")

        let second = challenge(notes, in: &engine)
        expect(
            engine.passed(challengeID: first.id).isEmpty && engine.challenge == second,
            "the previous challenge's result can't pass the current one"
        )
    }

    // MARK: - Lock, sleep, quit

    private static func runLifecycleTests() {
        var engine = makeEngine()
        let first = challenge(notes, in: &engine)
        _ = engine.passed(challengeID: first.id)
        expect(engine.lockAll() == [.hide(notes)], "locking the screen hides the unlocked app")
        expect(engine.unlocked == nil, "…and relocks it")
        _ = challenge(notes, in: &engine)

        expect(engine.lockAll() == [.lowerCurtain(notes, .cancelled)], "locking the screen cancels a challenge in progress")

        var prompting = makeEngine()
        let waiting = challenge(notes, in: &prompting)
        _ = prompting.systemPromptRequested(challengeID: waiting.id)
        expect(prompting.lockAll() == [.cancelSystemPrompt], "locking the screen dismisses a pending system prompt")

        var granted = makeEngine()
        let pending = challenge(notes, in: &granted)
        _ = granted.systemPromptRequested(challengeID: pending.id)
        _ = granted.systemPromptFinished(challengeID: pending.id, success: true, at: start)
        _ = granted.lockAll()
        _ = challenge(notes, in: &granted)
        expect(granted.unlocked == nil, "a prompt success doesn't carry across a screen lock")

        var quitting = makeEngine()
        _ = challenge(notes, in: &quitting)
        expect(
            quitting.appTerminated(pid: notes.pid) == [.lowerCurtain(notes, .abandoned)],
            "the covered app quitting drops the curtain"
        )
        let reopened = challenge(notes, in: &quitting)
        _ = quitting.passed(challengeID: reopened.id)
        expect(
            quitting.appTerminated(pid: notes.pid).isEmpty && quitting.unlocked == nil,
            "the unlocked app quitting just clears it"
        )
    }

    // MARK: - Reconcile

    private static func runReconcileTests() {
        var engine = makeEngine()
        let running = [
            Engine.RunningApp(app: notes, isHidden: false),
            Engine.RunningApp(app: chat, isHidden: true),
            Engine.RunningApp(app: browser, isHidden: false),
        ]
        expect(
            engine.reconcile(frontmost: browser, running: running, at: start) == [.hide(notes)],
            "a locked app showing in the background is put away — hidden ones and unlocked apps are left alone"
        )

        let effects = engine.reconcile(frontmost: notes, running: running, at: start)
        expect(
            effects.count == 1 && engine.challenge?.app == notes,
            "a locked app found frontmost is challenged rather than hidden"
        )
        expect(
            engine.reconcile(frontmost: notes, running: running, at: start).isEmpty,
            "reconciling again mid-challenge changes nothing"
        )

        let covering = engine.challenge!
        _ = engine.passed(challengeID: covering.id)
        expect(
            engine.reconcile(frontmost: notes, running: running, at: start).isEmpty,
            "the unlocked app is left on screen"
        )
        expect(
            engine.reconcile(frontmost: browser, running: running, at: start) == [.hide(notes)],
            "relocking and sweeping the same app hides it once, not twice"
        )

        // Touch ID succeeded and the app has been reopened, but it's visible a beat before it's frontmost.
        var reopening = makeEngine()
        let waiting = challenge(notes, in: &reopening)
        _ = reopening.systemPromptRequested(challengeID: waiting.id)
        _ = reopening.systemPromptFinished(challengeID: waiting.id, success: true, at: start)
        expect(
            reopening.reconcile(frontmost: browser, running: running, at: start).isEmpty,
            "an app reopened after a prompt success isn't hidden while it's still on its way forward"
        )
        expect(
            reopening.reconcile(frontmost: browser, running: running, at: start.addingTimeInterval(Engine.grantLifetime + 1))
                == [.hide(notes)],
            "…but is put away once that success has expired unclaimed"
        )

        var idle = Engine()
        expect(idle.reconcile(frontmost: notes, running: running, at: start).isEmpty, "a disabled engine hides nothing")
    }

    // MARK: - Settings changes

    private static func runConfigurationTests() {
        var engine = makeEngine()
        _ = challenge(notes, in: &engine)
        expect(
            engine.configure(isEnabled: true, lockedBundleIDs: [chat.bundleID]) == [.lowerCurtain(notes, .abandoned)],
            "taking the covered app off the list uncovers it"
        )
        expect(engine.appActivated(notes, at: start).isEmpty, "…and it's no longer challenged")

        let first = challenge(chat, in: &engine)
        _ = engine.passed(challengeID: first.id)
        expect(
            engine.configure(isEnabled: false, lockedBundleIDs: [chat.bundleID]).isEmpty && engine.unlocked == nil,
            "switching App Lock off forgets the unlocked app without hiding it"
        )
        expect(engine.appActivated(browser, at: start).isEmpty, "…and nothing is hidden afterwards")

        _ = engine.configure(isEnabled: true, lockedBundleIDs: [chat.bundleID])
        _ = challenge(chat, in: &engine)
        expect(engine.challenge != nil, "switching it back on challenges the app again")

        var prompting = makeEngine()
        let waiting = challenge(notes, in: &prompting)
        _ = prompting.systemPromptRequested(challengeID: waiting.id)
        expect(
            prompting.configure(isEnabled: false, lockedBundleIDs: []) == [.cancelSystemPrompt],
            "switching App Lock off dismisses a pending system prompt"
        )
    }
}
