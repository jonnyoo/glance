//
//  security_selftest.swift
//  glance (tools)
//
//  Offline, side-effect-free security self-test for pipeline matching,
//  fallback-embedder refusal, safe Vision feature-print decoding, UTF-8 ->
//  zeroizable UTF-16 keystroke buffer handling, device bezel multi-candidate
//  overlap, and canonical identity-name matching.
//
//  Compile and run:
//
//      swiftc -O -o /tmp/security_selftest \
//        glance/Liveness/LandmarkGeometry.swift \
//        glance/Liveness/DeviceBezelDetector.swift \
//        glance/FaceDetector.swift \
//        glance/FaceAligner.swift \
//        glance/FaceEmbedder.swift \
//        glance/ArcFaceEmbedder.swift \
//        glance/FaceRecognitionPipeline.swift \
//        glance/FaceEnrollmentStore.swift \
//        glance/SecureFaceStore.swift \
//        glance/SecureCredentialManager.swift \
//        glance/KeychainManager.swift \
//        glance/LockMonitor.swift \
//        glance/KeystrokeInjector.swift \
//        tools/security_selftest.swift \
//      && /tmp/security_selftest
//

import Foundation
import CoreGraphics
import Vision

private struct MockDiscriminativeEmbedder: FaceEmbedder {
    nonisolated let name = "Mock ArcFace"
    nonisolated let modelIdentifier = "arcface-w600k_mbf-v1"
    nonisolated let embeddingDimension = 2
    nonisolated let requiresAlignment = true
    nonisolated let isUnlockCapable = true

    nonisolated func embedding(for face: CGImage) throws -> [Float] {
        [1, 0]
    }
}

@main
struct SecuritySelfTest {
    @MainActor
    static func main() {
        runFallbackEmbedderRefusalTests()
        runMultiIdentityBestMatchTests()
        runVisionFeaturePrintBoundsTests()
        runUTF16KeystrokeHygieneTests()
        runDeviceBezelCandidateTests()
        runIdentityNameMatchingTests()
        print("\nAll security self-tests passed.")
    }

    @MainActor
    private static func runFallbackEmbedderRefusalTests() {
        let fallbackEmbedder = VisionFeaturePrintEmbedder()
        precondition(!fallbackEmbedder.isUnlockCapable, "FAIL: VisionFeaturePrintEmbedder must not be unlock-capable.")

        let fallbackPipeline = FaceRecognitionPipeline(
            embedder: fallbackEmbedder,
            usingFallbackEmbedder: true,
            fallbackReason: "simulated missing ArcFace"
        )
        let identity = FaceIdentity(
            id: UUID(),
            name: "Owner",
            samples: [FaceSample(embedding: [1, 0], pose: "center", capturedAt: Date(), quality: 0.9)],
            modelIdentifier: fallbackEmbedder.modelIdentifier,
            embeddingDimension: 2,
            createdAt: Date()
        )
        let scored = fallbackPipeline.score([1, 0], against: [identity])
        precondition(scored.count == 1 && scored[0].centroidSimilarity > 0.99, "FAIL: score() setup failed.")
        let match = fallbackPipeline.bestMatch(in: scored, threshold: 0.50)
        precondition(
            match == nil,
            "FAIL: pipeline matched using VisionFeaturePrintEmbedder fallback — weak feature print must never authorize unlock."
        )
        print("PASS: fallback VisionFeaturePrintEmbedder is refused by bestMatch.")
    }

    @MainActor
    private static func runMultiIdentityBestMatchTests() {
        let embedder = MockDiscriminativeEmbedder()
        let pipeline = FaceRecognitionPipeline(embedder: embedder, usingFallbackEmbedder: false, fallbackReason: nil)

        // 1. Stale top identity (higher centroid similarity 1.0) must not block a valid second identity (0.95).
        let staleTop = FaceIdentity(
            id: UUID(),
            name: "StaleProfile",
            samples: [FaceSample(embedding: [1, 0], pose: "center", capturedAt: Date(), quality: 0.9)],
            modelIdentifier: "legacy-model-v0",
            embeddingDimension: 2,
            createdAt: Date()
        )
        // 2. Blended centroid ([0.6, 0.8] + [0.6, -0.8] -> centroid [1, 0], centroidSim = 1.0, maxSampleSim = 0.60 < 0.63)
        //    must also be skipped rather than aborting bestMatch before checking valid identities below it.
        let blendedCentroidTop = FaceIdentity(
            id: UUID(),
            name: "BlendedPoses",
            samples: [
                FaceSample(embedding: [0.6, 0.8], pose: "left", capturedAt: Date(), quality: 0.9),
                FaceSample(embedding: [0.6, -0.8], pose: "right", capturedAt: Date(), quality: 0.9),
            ],
            modelIdentifier: embedder.modelIdentifier,
            embeddingDimension: 2,
            createdAt: Date()
        )
        let validRunnerUp = FaceIdentity(
            id: UUID(),
            name: "ValidGlassesProfile",
            samples: [FaceSample(embedding: [0.95, 0.31225], pose: "center", capturedAt: Date(), quality: 0.9)],
            modelIdentifier: embedder.modelIdentifier,
            embeddingDimension: 2,
            createdAt: Date()
        )

        let scored = pipeline.score([1, 0], against: [staleTop, blendedCentroidTop, validRunnerUp])
        let matched = pipeline.bestMatch(in: scored, threshold: 0.63)
        precondition(
            matched?.identity.id == validRunnerUp.id,
            "FAIL: bestMatch stopped at stale/blended first entry instead of matching valid runner-up, got \(String(describing: matched?.identity.name))."
        )
        print("PASS: bestMatch skips stale or low-sample-similarity top candidates to match valid enrolled identities.")
    }

    private static func runVisionFeaturePrintBoundsTests() {
        // Truncated buffer must throw rather than read out-of-bounds memory.
        let truncated = Data(repeating: 0, count: 12)
        do {
            _ = try VisionFeaturePrintEmbedder.floatVector(from: truncated, elementCount: 8, elementType: .float)
            fatalError("FAIL: truncated float buffer should throw.")
        } catch FaceEmbedderError.corruptedObservationData {
            // Expected.
        } catch {
            fatalError("FAIL: unexpected error for truncated buffer: \(error)")
        }

        // Unaligned slice (offset by 1 byte) must decode both Float and Double without alignment traps.
        let expectedFloats: [Float] = [0.25, -0.5, 1.75, 3.5]
        var unalignedFloatBytes = Data([0xAA])
        expectedFloats.withUnsafeBytes { unalignedFloatBytes.append(contentsOf: $0) }
        let floatSlice = unalignedFloatBytes.dropFirst(1)
        guard let decodedFloats = try? VisionFeaturePrintEmbedder.floatVector(
            from: floatSlice, elementCount: expectedFloats.count, elementType: .float
        ) else {
            fatalError("FAIL: unaligned Float slice failed to decode.")
        }
        precondition(decodedFloats == expectedFloats, "FAIL: unaligned Float decode mismatch: \(decodedFloats).")

        let expectedDoubles: [Double] = [0.125, -2.5, 4.0]
        var unalignedDoubleBytes = Data([0xBB])
        expectedDoubles.withUnsafeBytes { unalignedDoubleBytes.append(contentsOf: $0) }
        let doubleSlice = unalignedDoubleBytes.dropFirst(1)
        guard let decodedFromDouble = try? VisionFeaturePrintEmbedder.floatVector(
            from: doubleSlice, elementCount: expectedDoubles.count, elementType: .double
        ) else {
            fatalError("FAIL: unaligned Double slice failed to decode.")
        }
        precondition(
            decodedFromDouble == expectedDoubles.map(Float.init),
            "FAIL: unaligned Double decode mismatch: \(decodedFromDouble)."
        )
        print("PASS: VisionFeaturePrintEmbedder validates buffer byte length and safely decodes unaligned slices.")
    }

    private static func runUTF16KeystrokeHygieneTests() {
        let complexPassword = "S3cr3t!päss🔑wörd🔒1234567890"
        let utf8Data = Data(complexPassword.utf8)

        guard var utf16 = KeystrokeInjector.decodeUTF8ToUTF16(utf8Data) else {
            fatalError("FAIL: decodeUTF8ToUTF16 rejected valid UTF-8 password.")
        }
        precondition(
            utf16 == Array(complexPassword.utf16),
            "FAIL: decodeUTF8ToUTF16 output did not match String.utf16 code units."
        )

        // Verify batching never splits surrogate pairs even when an emoji straddles index 19/20.
        let boundaryEmoji = String(repeating: "a", count: 19) + "🔒" + "z"
        guard let boundaryUTF16 = KeystrokeInjector.decodeUTF8ToUTF16(Data(boundaryEmoji.utf8)) else {
            fatalError("FAIL: boundary emoji UTF-8 decode failed.")
        }
        let ranges = KeystrokeInjector.splitUTF16BatchRanges(boundaryUTF16, maxBatchLength: 20)
        precondition(
            ranges == [0..<19, 19..<22],
            "FAIL: surrogate pair at index 19..20 was split across batches: \(ranges)."
        )

        // Invalid UTF-8 must fail closed.
        let invalidUTF8 = Data([0xC3, 0x28])
        precondition(
            KeystrokeInjector.decodeUTF8ToUTF16(invalidUTF8) == nil,
            "FAIL: invalid UTF-8 sequence should return nil."
        )

        // Zeroization must wipe every UInt16 in place.
        KeystrokeInjector.zeroizeUTF16Buffer(&utf16)
        precondition(
            utf16.allSatisfy { $0 == 0 },
            "FAIL: zeroizeUTF16Buffer left non-zero code units in memory."
        )
        print("PASS: UTF-8 -> UTF-16 direct decoding, surrogate-safe batching, invalid-UTF8 rejection, and zeroization succeeded.")
    }

    private static func runDeviceBezelCandidateTests() {
        let faceBox = CGRect(x: 520, y: 150, width: 80, height: 80)
        let hugeBackgroundMonitor = CGRect(x: 0, y: 0, width: 500, height: 400) // area 200,000, overlap 0
        let phoneOverFace = CGRect(x: 500, y: 120, width: 120, height: 180)     // area 21,600, overlap 1.0

        let obs = DeviceBezelDetector.bestCandidateOverlap(
            candidates: [hugeBackgroundMonitor, phoneOverFace],
            faceBoundingBox: faceBox
        )
        guard let overlap = obs.faceOverlapFraction, overlap > 0.99 else {
            fatalError("FAIL: larger background rectangle masked overlapping phone bezel (got \(String(describing: obs.faceOverlapFraction))).")
        }
        print("PASS: DeviceBezelDetector catches overlapping phone bezel even when a larger background rectangle is present.")
    }

    private static func runIdentityNameMatchingTests() {
        precondition(FaceEnrollmentStore.namesMatch("Salim", "salim"), "FAIL: case-insensitive match failed.")
        precondition(FaceEnrollmentStore.namesMatch("Álex", "alex"), "FAIL: diacritic-insensitive match failed.")
        precondition(!FaceEnrollmentStore.namesMatch("Salim", "Karim"), "FAIL: distinct names matched.")
        print("PASS: FaceEnrollmentStore.namesMatch enforces consistent case- and diacritic-insensitive matching.")
    }
}

