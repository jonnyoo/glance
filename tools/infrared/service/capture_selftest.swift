// Explicit hardware test against an approved service. Images are never logged.
import Foundation

@main
struct CaptureSelfTest {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let team = CommandLine.arguments[1]
        guard team.range(of: "^[A-Z0-9]{10}$", options: .regularExpression) != nil else { exit(2) }
        let connection = NSXPCConnection(machServiceName: "local.glance.ir-lab.camera-helper", options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: InfraredServiceProtocol.self)
        connection.setCodeSigningRequirement("anchor apple generic and identifier \"local.glance.ir-lab.camera-helper\" and certificate leaf[subject.OU] = \"\(team)\"")
        connection.invalidationHandler = { print("Service disconnected."); exit(1) }
        connection.interruptionHandler = { print("Service interrupted."); exit(1) }
        connection.resume()
        guard let remote = connection.remoteObjectProxyWithErrorHandler({ _ in
            print("Cannot reach the approved service."); exit(1)
        }) as? InfraredServiceProtocol else { exit(1) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 45) {
            print("Hardware test timed out."); exit(1)
        }
        func capture(cancel: Bool = false) async throws -> InfraredProbeResult {
            let id = UUID().uuidString
            return try await withCheckedThrowingContinuation { continuation in
                remote.capture(id) { data, error in
                    guard let data else {
                        continuation.resume(throwing: InfraredProbeError.execution(error ?? "No response")); return
                    }
                    do { continuation.resume(returning: try InfraredProbeResult.decode(data)) }
                    catch { continuation.resume(throwing: error) }
                }
                if cancel { remote.cancel(id) }
            }
        }
        // Even when already cancelled, a request must complete without a frame.
        let cancelled = try await capture(cancel: true)
        guard !cancelled.ok, cancelled.stage == "cancelled", cancelled.pixels == nil else {
            print("Cancellation test failed."); exit(1)
        }
        print("Service capture cancellation passed.")
        for number in 1...2 {
            let result = try await capture()
            _ = try result.image()
            print("Capture \(number): \(result.frames ?? 0) valid IR frames, \(result.rejected ?? 0) rejected; image decoded in memory.")
        }
        print("Repeated service captures passed.")
        exit(0)
    }
}
