//
//  FaceLabController.swift
//  glance
//
//  Orchestrates milestones A-F for the Face Lab debug tab: wires the camera,
//  detector, embedder, and enrollment store together and exposes everything
//  the UI needs. Deliberately never touches LockMonitor, KeystrokeInjector,
//  or SecureCredentialManager — connecting to unlock is milestone G, later.
//

import Foundation
import CoreGraphics
import Observation

struct RecognitionResult: Identifiable {
    let id = UUID()
    let name: String
    let similarityPercent: Double
}

@Observable
@MainActor
final class FaceLabController {
    let camera = CameraManager()
    let store = FaceEnrollmentStore()
    private let embedder: FaceEmbedder = VisionFeaturePrintEmbedder()

    private(set) var detectedFaces: [DetectedFace] = []
    private(set) var faceQuality: Float?
    private(set) var croppedFace: CGImage?
    private(set) var currentEmbedding: [Float]?

    var enrollName: String = ""
    /// Percent (0...100) cosine-similarity cutoff for a "match" verdict.
    /// Vision's general-purpose feature print has no universally-correct
    /// cutoff, so this is tunable in the UI rather than a fixed constant.
    var threshold: Double = 60

    private(set) var recognitionResults: [RecognitionResult] = []
    private(set) var bestMatch: RecognitionResult?

    private(set) var logLines: [String] = []

    private var isProcessingFrame = false

    init() {
        observeFrames()
    }

    func start() async {
        await camera.start()
        if let error = camera.errorMessage {
            log(error)
        } else {
            log("Camera started.")
        }
    }

    func stop() {
        camera.stop()
        detectedFaces = []
        faceQuality = nil
        croppedFace = nil
        currentEmbedding = nil
        log("Camera stopped.")
    }

    /// Re-subscribes on every change, matching the pattern used by
    /// `POCController` for `LockMonitor` — `withObservationTracking` only
    /// fires once per registration.
    private func observeFrames() {
        withObservationTracking {
            _ = camera.currentFrame
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeFrames()
                await self?.processLatestFrame()
            }
        }
    }

    /// Skips frames that arrive while a previous one is still being
    /// processed — a simple "always work on the latest frame" throttle
    /// instead of a fixed timer.
    private func processLatestFrame() async {
        guard !isProcessingFrame, let frame = camera.currentFrame else { return }
        isProcessingFrame = true
        defer { isProcessingFrame = false }

        do {
            let faces = try await Task.detached(priority: .userInitiated) {
                try FaceDetector.detectFaces(in: frame)
            }.value
            detectedFaces = faces
            faceQuality = faces.first?.quality

            if let first = faces.first, let crop = FaceDetector.crop(first, from: frame) {
                croppedFace = crop
                let embedder = self.embedder
                currentEmbedding = try? await Task.detached(priority: .userInitiated) {
                    try embedder.embedding(for: crop)
                }.value
            } else {
                croppedFace = nil
                currentEmbedding = nil
            }
        } catch {
            log("Detection error: \(error.localizedDescription)")
        }
    }

    // MARK: - Milestone E: enrollment

    func captureSample() {
        guard let embedding = currentEmbedding else {
            log("No face detected — can't capture a sample.")
            return
        }
        let trimmedName = enrollName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            log("Enter a name before capturing a sample.")
            return
        }
        store.addSample(name: trimmedName, embedding: embedding, embedderName: embedder.name)
        log("Captured sample for \"\(trimmedName)\" (\(embedding.count)-dim embedding).")
    }

    func deleteIdentity(_ identity: FaceIdentity) {
        store.delete(identity)
        log("Deleted \"\(identity.name)\".")
    }

    // MARK: - Milestone F: recognition

    func recognize() {
        guard let embedding = currentEmbedding else {
            log("No face detected — can't recognize.")
            recognitionResults = []
            bestMatch = nil
            return
        }
        guard !store.identities.isEmpty else {
            log("No enrolled identities yet — capture a sample first.")
            recognitionResults = []
            bestMatch = nil
            return
        }

        let results = store.identities.compactMap { identity -> RecognitionResult? in
            guard let template = identity.template else { return nil }
            return RecognitionResult(
                name: identity.name,
                similarityPercent: FaceEmbedding.similarityPercent(embedding, template)
            )
        }.sorted { $0.similarityPercent > $1.similarityPercent }

        recognitionResults = results
        bestMatch = results.first
        if let best = results.first {
            let verdict = best.similarityPercent >= threshold ? "MATCH" : "no match"
            log("Recognize: best = \(best.name) at \(String(format: "%.1f", best.similarityPercent))% -> \(verdict)")
        }
    }

    private func log(_ message: String) {
        let timestamp = Date().formatted(date: .omitted, time: .standard)
        logLines.append("[\(timestamp)] \(message)")
        if logLines.count > 200 {
            logLines.removeFirst(logLines.count - 200)
        }
    }
}
