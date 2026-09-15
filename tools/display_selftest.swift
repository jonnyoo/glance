//
//  display_selftest.swift
//  glance (tools)
//
//  Offline test for the pure display decisions in DisplayMath.swift. This
//  project has no test target, so this compiles against the real file:
//
//      swiftc -O -o /tmp/display_selftest \
//        glance/NotchOverlay/DisplayMath.swift \
//        tools/display_selftest.swift \
//      && /tmp/display_selftest
//
//  The ids below are real readings from a MacBookPro18,3 with one external
//  monitor: display numbers 1 and 2, and the UUIDs CoreGraphics reported.
//

import CoreGraphics
import Foundation

@main
enum DisplaySelfTest {
    static var failures = 0

    static func check(_ condition: Bool, _ label: String) {
        print("\(condition ? "PASS" : "FAIL")  \(label)")
        if !condition { failures += 1 }
    }

    static func main() {
        let builtInUUID = "37D8832A-2D66-02CA-B9F7-8F30A301B230"
        let externalUUID = "78303FA3-F26A-4E09-9963-990E3553D621"

        print("-- persistentID")
        check(DisplayMath.persistentID(uuid: builtInUUID, number: 1) == builtInUUID, "prefers the UUID")
        check(DisplayMath.persistentID(uuid: nil, number: 2) == "2", "falls back to the display number")

        print("-- savedID(_:matchesUUID:number:)")
        check(DisplayMath.savedID(builtInUUID, matchesUUID: builtInUUID, number: 1), "UUID matches its display")
        check(DisplayMath.savedID(builtInUUID, matchesUUID: builtInUUID, number: 7),
              "UUID still matches after the display number changes (reboot, replug)")
        check(!DisplayMath.savedID(builtInUUID, matchesUUID: externalUUID, number: 2), "UUID does not match another display")
        check(DisplayMath.savedID(builtInUUID.lowercased(), matchesUUID: builtInUUID, number: 1), "UUID matches regardless of case")
        check(DisplayMath.savedID("2", matchesUUID: externalUUID, number: 2), "legacy number still matches")
        check(!DisplayMath.savedID("2", matchesUUID: builtInUUID, number: 1), "legacy number does not match another display")
        check(!DisplayMath.savedID("12", matchesUUID: nil, number: 1), "no prefix match on numbers")
        check(DisplayMath.savedID("1", matchesUUID: nil, number: 1), "number matches when no UUID is available")
        check(!DisplayMath.savedID(builtInUUID, matchesUUID: nil, number: 1), "UUID cannot match a display with no UUID")
        check(!DisplayMath.savedID("", matchesUUID: builtInUUID, number: 1), "empty id matches nothing")
        // The rewrite in preferredScreen() fires when the saved id matched but differs from persistentID.
        let legacy = "1"
        check(DisplayMath.savedID(legacy, matchesUUID: builtInUUID, number: 1)
              && DisplayMath.persistentID(uuid: builtInUUID, number: 1) != legacy, "legacy match is detectable for rewrite")
        check(DisplayMath.persistentID(uuid: nil, number: 1) == legacy, "no rewrite loop when there is no UUID")

        // Built-in screen of the same MacBookPro18,3 at default scaling: frame width 1512,
        // auxiliaryTopLeftArea width 663, auxiliaryTopRightArea width 664, gap 663 -> 848.
        print("-- notchWidth(screenWidth:leftAreaWidth:rightAreaWidth:)")
        let fallback = DisplayMath.fallbackNotchWidth
        check(DisplayMath.notchWidth(screenWidth: 1512, leftAreaWidth: 663, rightAreaWidth: 664) == 185,
              "measured 14\" MBP notch is used as-is (185, not floored to 200)")
        check(DisplayMath.notchWidth(screenWidth: 1280, leftAreaWidth: 565, rightAreaWidth: 565) == 150,
              "a smaller scaled notch below the old 200 floor is kept")
        check(DisplayMath.notchWidth(screenWidth: 1728, leftAreaWidth: 764, rightAreaWidth: 764) == 200,
              "a 200pt notch is kept")
        check(DisplayMath.notchWidth(screenWidth: 1512, leftAreaWidth: nil, rightAreaWidth: 664) == fallback,
              "missing left area falls back instead of reading 0")
        check(DisplayMath.notchWidth(screenWidth: 1512, leftAreaWidth: 663, rightAreaWidth: nil) == fallback,
              "missing right area falls back instead of reading 0")
        check(DisplayMath.notchWidth(screenWidth: 1512, leftAreaWidth: 0, rightAreaWidth: 0) == fallback,
              "empty areas (whole screen) fall back")
        check(DisplayMath.notchWidth(screenWidth: 1512, leftAreaWidth: 700, rightAreaWidth: 700) == fallback,
              "an implausibly narrow reading (112) falls back")
        check(DisplayMath.notchWidth(screenWidth: 1512, leftAreaWidth: 800, rightAreaWidth: 800) == fallback,
              "a negative reading falls back")
        check(DisplayMath.notchWidth(screenWidth: 1512, leftAreaWidth: 663 - 400, rightAreaWidth: 664 - 400) == fallback,
              "a reading of half the screen or more falls back")
        check(DisplayMath.notchWidth(screenWidth: 1512, leftAreaWidth: 696, rightAreaWidth: 696) == 120,
              "the plausibility floor itself is accepted")

        print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
        if failures > 0 { exit(1) }
    }
}
