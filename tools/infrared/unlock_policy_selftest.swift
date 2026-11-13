import Foundation

@main
struct UnlockPolicySelfTest {
    static func main() throws {
        let good = InfraredSimilarity(centroid: 0.90, minimumReference: 0.82, maximumReference: 0.96)
        func permits(_ score: InfraredSimilarity = good, threshold: Double = 0.7, age: Double = 7,
                     sameIdentity: Bool = true, sameScan: Bool = true, session: Bool = true,
                     locked: Bool = true, sleeping: Bool = false, live: Bool = true, helper: Bool = true) -> Bool {
            InfraredUnlockPolicy.permits(score: score, threshold: threshold, elapsed: age,
                sameIdentityAndEnrollment: sameIdentity, sameScan: sameScan, sessionUnlocked: session,
                screenLocked: locked, sleeping: sleeping, livenessConfirmed: live, helperEnabled: helper)
        }
        precondition(permits())
        precondition(!permits(age: 15.001) && !permits(age: -1) && !permits(age: .nan))
        precondition(!permits(threshold: .nan) && !permits(threshold: 0) && !permits(threshold: 1.1))
        precondition(!permits(sameIdentity: false) && !permits(sameScan: false))
        precondition(!permits(session: false) && !permits(locked: false) && !permits(sleeping: true))
        precondition(!permits(live: false) && !permits(helper: false))
        precondition(!permits(InfraredSimilarity(centroid: 0.99, minimumReference: 0.2, maximumReference: 0.99)))
        precondition(!permits(InfraredSimilarity(centroid: .nan, minimumReference: 0.9, maximumReference: 0.9)))
        precondition(!permits(InfraredSimilarity(centroid: 0.9, minimumReference: .infinity, maximumReference: .infinity)))
        precondition(!permits(InfraredSimilarity(centroid: 0.9, minimumReference: 0.9, maximumReference: 0.8)))
        let vectors = (0..<3).map { _ in InfraredFaceSample(captureID: UUID(), modelIdentifier: InfraredEnrollment.expectedModelIdentifier,
            embedding: [1] + [Float](repeating: 0, count: 511)) }
        let enrollment = try InfraredEnrollment(samples: vectors)
        precondition(enrollment.isUsable)
        let restored = try JSONDecoder().decode(InfraredEnrollment.self, from: JSONEncoder().encode(enrollment))
        precondition(restored == enrollment)
        let match = try restored.compare(InfraredFaceSample(captureID: UUID(), modelIdentifier: InfraredEnrollment.expectedModelIdentifier,
            embedding: [2] + [Float](repeating: 0, count: 511)))
        precondition(permits(match))
        var invalid = try JSONSerialization.jsonObject(with: JSONEncoder().encode(enrollment)) as! [String: Any]
        invalid["modelIdentifier"] = "rgb-other"
        let stale = try JSONDecoder().decode(InfraredEnrollment.self, from: JSONSerialization.data(withJSONObject: invalid))
        precondition(!stale.isUsable)
        print("IR unlock gate passed: success plus stale/wrong identity, scan, state, threshold, liveness, helper and malformed evidence denials; encrypted-record payload round trip.")
    }
}
