//
//  app_lock_selftest.swift
//  glance (tools)
//
//  Offline test for AppLockState's relock policies. This project has no test target, so this compiles as a
//  standalone script:
//
//      swiftc -parse-as-library -o /tmp/app_lock_selftest \
//        glance/AppLock/AppLockState.swift tools/app_lock_selftest.swift && /tmp/app_lock_selftest
//

import Foundation

@main
enum AppLockSelfTest {
    static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        if condition { print("ok   \(message)") } else { failures += 1; print("FAIL \(message)") }
    }

    static func main() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let app = "net.whatsapp.WhatsApp"
        var state = AppLockState()

        for policy in AppLockRelockPolicy.allCases {
            check(state.needsVerification(bundleID: app, pid: 10, policy: policy, now: t0),
                  "\(policy): an app never unlocked needs a check")
        }

        state.markUnlocked(bundleID: app, pid: 10, at: t0)
        for policy in AppLockRelockPolicy.allCases {
            check(!state.needsVerification(bundleID: app, pid: 10, policy: policy, now: t0.addingTimeInterval(1)),
                  "\(policy): coming back within the 2 s grace needs no check")
        }
        check(state.needsVerification(bundleID: app, pid: 11, policy: .onQuit, now: t0.addingTimeInterval(1)),
              "a relaunched app (new pid) needs a check")
        check(!state.needsVerification(bundleID: app, pid: 10, policy: .onQuit, now: t0.addingTimeInterval(3600)),
              "onQuit: still open an hour later")
        check(state.needsVerification(bundleID: app, pid: 10, policy: .everyActivation, now: t0.addingTimeInterval(10)),
              "everyActivation: checks again after the grace")

        state.markDeactivated(bundleID: app, pid: 10, at: t0.addingTimeInterval(60))
        check(!state.needsVerification(bundleID: app, pid: 10, policy: .afterFiveMinutesAway, now: t0.addingTimeInterval(60 + 299)),
              "afterFiveMinutesAway: back within 5 min needs no check")
        check(state.needsVerification(bundleID: app, pid: 10, policy: .afterFiveMinutesAway, now: t0.addingTimeInterval(60 + 301)),
              "afterFiveMinutesAway: away over 5 min needs a check")
        state.markActivated(bundleID: app, pid: 10)
        check(!state.needsVerification(bundleID: app, pid: 10, policy: .afterFiveMinutesAway, now: t0.addingTimeInterval(60 + 600)),
              "afterFiveMinutesAway: coming back resets the away timer")
        state.markDeactivated(bundleID: app, pid: 10, at: t0.addingTimeInterval(1000))
        state.markDeactivated(bundleID: app, pid: 10, at: t0.addingTimeInterval(1200))
        check(state.needsVerification(bundleID: app, pid: 10, policy: .afterFiveMinutesAway, now: t0.addingTimeInterval(1000 + 301)),
              "afterFiveMinutesAway: the first deactivation starts the timer")

        state.markUnlocked(bundleID: app, pid: 10, at: t0)
        state.markTerminated(bundleID: app)
        check(state.needsVerification(bundleID: app, pid: 10, policy: .onQuit, now: t0.addingTimeInterval(10)),
              "quitting the app locks it again")

        state.markUnlocked(bundleID: app, pid: 10, at: t0)
        state.markUnlocked(bundleID: "com.apple.Notes", pid: 20, at: t0)
        state.lockAll()
        check(state.needsVerification(bundleID: app, pid: 10, policy: .onQuit, now: t0.addingTimeInterval(10))
              && state.needsVerification(bundleID: "com.apple.Notes", pid: 20, policy: .onQuit, now: t0.addingTimeInterval(10)),
              "lockAll locks every app")

        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
