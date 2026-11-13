// All events go to an in-memory sink. This test NEVER posts keyboard events.
import Foundation
import CoreGraphics

@main struct InjectionSelfTest {
    @MainActor static func main() async throws {
        var events: [(CGEventType, Int64)] = []
        func transition(_ event: CGEvent) -> CGEventType {
            // CGEvent represents the physical Command key as flagsChanged,
            // even when constructed with keyboardEventSource/keyDown.
            if event.type == .flagsChanged && event.getIntegerValueField(.keyboardEventKeycode) == 0x37 {
                return event.flags.contains(.maskCommand) ? .keyDown : .keyUp
            }
            return event.type
        }
        func record(_ event: CGEvent) { events.append((transition(event), event.getIntegerValueField(.keyboardEventKeycode))) }
        do {
            try await KeystrokeInjector.typeAndReturn(Data("test".utf8), stillAuthorized: { false }, accessibilityCheck: { true }, postEvent: record)
            fatalError("Denied authorization must fail")
        } catch KeystrokeError.authorizationExpired {}
        precondition(events.isEmpty)
        try await KeystrokeInjector.typeAndReturn(Data("abc".utf8), accessibilityCheck: { true }, postEvent: record)
        precondition(events.filter { $0.0 == .keyDown && $0.1 == 0 }.count == 3)
        precondition(events.filter { $0.0 == .keyDown && $0.1 == 0x24 }.count == 1)
        events = []
        var allowed = true
        do {
            try await KeystrokeInjector.typeAndReturn(Data("abc".utf8), stillAuthorized: { allowed }, accessibilityCheck: { true }) { event in
                record(event)
                if event.type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 0 { allowed = false }
            }
            fatalError("Revocation must stop typing")
        } catch KeystrokeError.authorizationExpired {}
        precondition(events.filter { $0.0 == .keyDown && $0.1 == 0 }.count == 1)
        precondition(events.filter { $0.0 == .keyUp && $0.1 == 0 }.count == 1)
        precondition(!events.contains { $0.1 == 0x24 })
        events = []
        var operation: Task<Void, Error>?
        operation = Task { @MainActor in
            try await KeystrokeInjector.typeAndReturn(Data("abc".utf8), accessibilityCheck: { true }) { event in
                record(event)
                if event.type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 0 { operation?.cancel() }
            }
        }
        do { try await operation!.value; fatalError("Cancellation must interrupt typing") } catch is CancellationError {}
        precondition(events.filter { $0.0 == .keyDown }.count == events.filter { $0.0 == .keyUp }.count)
        precondition(!events.contains { $0.1 == 0x24 })

        // Unicode payloads stay ordered and intact at the shorter character
        // pace, including repeated characters, combining marks and emoji.
        let fixture = "aA11 ée\u{301} 👩🏽‍💻漢字"
        var unicodeDown = "", unicodeUp = ""
        events = []
        try await KeystrokeInjector.typeAndReturn(Data(fixture.utf8), accessibilityCheck: { true }) { event in
            record(event)
            guard event.getIntegerValueField(.keyboardEventKeycode) == 0 else { return }
            var buffer = [UniChar](repeating: 0, count: 64)
            var count = 0
            event.keyboardGetUnicodeString(maxStringLength: buffer.count, actualStringLength: &count, unicodeString: &buffer)
            let text = String(decoding: buffer.prefix(count), as: UTF16.self)
            if event.type == .keyDown { unicodeDown += text }
            if event.type == .keyUp { unicodeUp += text }
        }
        precondition(Array(unicodeDown.utf16) == Array(fixture.utf16))
        precondition(Array(unicodeUp.utf16) == Array(fixture.utf16))
        let completeDowns = events.filter { $0.0 == .keyDown }.map { $0.1 }
        precondition(Array(completeDowns.prefix(4)) == [0x37, 0x7C, 0x37, 0x33])
        precondition(completeDowns.last == 0x24)

        // Revoke or cancel at every key-down boundary, including modifiers,
        // clearing commands, the last character and Return itself. Before
        // Return, neither path may post another key-down. After Return, the
        // already-authorized submission is complete; only releases remain.
        for cancel in [false, true] {
            for boundary in completeDowns.indices {
                events = []
                allowed = true
                var downCount = 0
                var task: Task<Void, Error>?
                task = Task { @MainActor in
                    try await KeystrokeInjector.typeAndReturn(Data(fixture.utf8), stillAuthorized: { allowed }, accessibilityCheck: { true }) { event in
                        record(event)
                        if transition(event) == .keyDown {
                            downCount += 1
                            if downCount == boundary + 1 {
                                if cancel { task?.cancel() } else { allowed = false }
                            }
                        }
                    }
                }
                var completed = false
                do { try await task!.value; completed = true }
                catch is CancellationError { precondition(cancel) }
                catch KeystrokeError.authorizationExpired { precondition(!cancel) }
                precondition(completed == (boundary == completeDowns.count - 1))
                let downs = events.filter { $0.0 == .keyDown }.map { $0.1 }
                let ups = events.filter { $0.0 == .keyUp }.map { $0.1 }
                precondition(downs == Array(completeDowns.prefix(boundary + 1)))
                precondition(downs.sorted() == ups.sorted(), "Every posted key must be released")
                precondition(downs.contains(0x24) == completed)
            }
        }
        print("Injection tests passed in memory: Unicode order, every cancellation/revocation boundary, balanced releases and accurate final-Return submission status.")
    }
}
