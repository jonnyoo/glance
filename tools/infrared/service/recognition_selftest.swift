// Explicit BRIO hardware experiment. Logs numeric measurements, never images or
// face vectors. Run from a signed test bundle containing ArcFace.mlmodelc.
import Foundation

@main
struct RecognitionSelfTest {
    static func main() async {
        do { try await run() }
        catch { print("IR comparison test could not complete: \(error.localizedDescription)"); exit(1) }
    }

    static func run() async throws {
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
        DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
            print("Hardware comparison test timed out."); exit(1)
        }
        let analyzer = InfraredFaceAnalyzer()
        var reference = InfraredReference()
        for index in 1...4 {
            let id = UUID()
            let result: InfraredProbeResult = try await withCheckedThrowingContinuation { continuation in
                remote.capture(id.uuidString) { data, error in
                    guard let data else {
                        continuation.resume(throwing: InfraredProbeError.execution(error ?? "No response")); return
                    }
                    do { continuation.resume(returning: try InfraredProbeResult.decode(data)) }
                    catch { continuation.resume(throwing: error) }
                }
            }
            let sample = try await analyzer.sample(from: result.image(), captureID: id)
            if index <= 3 {
                try reference.add(sample)
                print("Reference \(index)/3: \(result.frames ?? 0) IR frames; five-point alignment and 512-dimensional sample validated.")
            } else {
                let score = try reference.compare(sample)
                print(String(format: "Fresh comparison: centroid %.3f; reference range %.3f–%.3f. No authentication decision.",
                    score.centroid, score.minimumReference, score.maximumReference))
            }
        }
        reference.clear()
        print("IR comparison capture, alignment, inference and session clearing completed.")
        exit(0)
    }
}
