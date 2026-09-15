//
//  camera_display_selftest.swift
//  glance (tools)
//
//  Offline, camera-free test for which camera override glance consults:
//  `CameraDeviceCatalog.targetsBuiltInDisplay`, the pure half of
//  `isUsingBuiltInDisplay()`. This project has no test target, so this
//  compiles as a standalone script against the real catalog file:
//
//      swiftc -default-isolation MainActor -o /tmp/camera_display_selftest \
//        glance/CameraDeviceCatalog.swift \
//        glance/NotchOverlay/DisplayMath.swift \
//        tools/camera_display_selftest.swift \
//      && /tmp/camera_display_selftest
//
//  `GlanceSettings.swift` is deliberately stubbed below rather than
//  compiled: the catalog only reads four optional strings from it, and the
//  real file drags in liveness types that have nothing to do with display
//  selection.
//

import AppKit

final class GlanceSettings {
    static let shared = GlanceSettings()
    var preferredDisplayID: String?
    var defaultCameraID: String?
    var builtInDisplayCameraID: String?
    var externalDisplayCameraID: String?
}

@main
struct CameraDisplaySelfTest {
    typealias Display = CameraDeviceCatalog.TargetDisplay

    static var failures = 0

    static func check(_ name: String, _ actual: Bool, _ expected: Bool) {
        let ok = actual == expected
        if !ok { failures += 1 }
        print("\(ok ? "PASS" : "FAIL")  \(name) (expected \(expected), got \(actual))")
    }

    static func main() {
        let laptop = Display(number: 1, uuid: "37D8832A-2D66-02CA-B9F7-8F30A301B230", isBuiltIn: true)
        let monitor = Display(number: 12, uuid: "9A1B2C3D-0000-1111-2222-333344445555", isBuiltIn: false)
        let docked = [laptop, monitor]

        // The reported bug: docked, lid open, nothing pinned, key window on the monitor. Holds for notchless laptops
        // too (`laptop` carries no notch fact): the overlay takes the built-in panel, not `NSScreen.main`, there as well.
        check("unpinned, docked, main on external -> built-in override",
              CameraDeviceCatalog.targetsBuiltInDisplay(pinnedID: nil, screens: docked, main: monitor), true)
        check("unpinned, docked, main on built-in -> built-in override (key window doesn't flip it)",
              CameraDeviceCatalog.targetsBuiltInDisplay(pinnedID: nil, screens: docked, main: laptop), true)
        check("unpinned, clamshell (built-in panel absent) -> external override",
              CameraDeviceCatalog.targetsBuiltInDisplay(pinnedID: nil, screens: [monitor], main: monitor), false)

        // A pin decides it when connected, in either saved format.
        check("pinned external by legacy number",
              CameraDeviceCatalog.targetsBuiltInDisplay(pinnedID: "12", screens: docked, main: laptop), false)
        check("pinned external by UUID",
              CameraDeviceCatalog.targetsBuiltInDisplay(pinnedID: monitor.uuid, screens: docked, main: laptop), false)
        check("pinned external by lowercased UUID",
              CameraDeviceCatalog.targetsBuiltInDisplay(pinnedID: monitor.uuid!.lowercased(), screens: docked, main: laptop), false)
        check("pinned built-in by UUID while main is external",
              CameraDeviceCatalog.targetsBuiltInDisplay(pinnedID: laptop.uuid, screens: docked, main: monitor), true)

        // A stale pin falls through to the unpinned choice instead of sticking.
        check("stale pin, built-in connected",
              CameraDeviceCatalog.targetsBuiltInDisplay(pinnedID: "99", screens: docked, main: monitor), true)
        check("stale built-in pin in clamshell",
              CameraDeviceCatalog.targetsBuiltInDisplay(pinnedID: laptop.uuid, screens: [monitor], main: monitor), false)

        // Nothing to go on keeps the old default.
        check("no screens, no main -> built-in override (unchanged default)",
              CameraDeviceCatalog.targetsBuiltInDisplay(pinnedID: nil, screens: [], main: nil), true)

        // Matching must be exact, not a prefix or a cross-format coincidence.
        check("number id does not prefix-match", monitor.matches(displayID: "1"), false)
        check("number id matches exactly", monitor.matches(displayID: "12"), true)
        check("UUID of another display does not match", monitor.matches(displayID: laptop.uuid!), false)
        check("display without a UUID still matches by number",
              Display(number: 7, uuid: nil, isBuiltIn: false).matches(displayID: "7"), true)

        // Live screens: just proves the NSScreen adapter produces a match for its own ids.
        for screen in NSScreen.screens {
            guard let display = Display(screen) else { continue }
            check("live screen \(display.number) matches its own number", display.matches(displayID: String(display.number)), true)
            if let uuid = display.uuid {
                check("live screen \(display.number) matches its own UUID", display.matches(displayID: uuid), true)
            }
        }

        print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
