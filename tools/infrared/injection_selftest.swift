// All events go to an in-memory sink. This test NEVER posts keyboard events.
import Foundation
import CoreGraphics

@main struct InjectionSelfTest {
    @MainActor static func main() async throws {
        var events: [(CGEventType, Int64)] = []
        func record(_ event: CGEvent) { events.append((event.type, event.getIntegerValueField(.keyboardEventKeycode))) }
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
        print("Injection tests passed with an in-memory sink: denial posts nothing; revocation/cancellation stop characters and Return and release held keys.")
    }
}
