//
//  FaceLabController.swift
//  glance
//
//  Orchestrates the Face Lab debug tab: wires the camera to
//  FaceRecognitionPipeline (detect -> align -> embed) and the encrypted
//  enrollment store, and exposes everything the UI needs. Deliberately
//  never touches LockMonitor, KeystrokeInjector, or SecureCredentialManager
//  for *unlocking* — connecting recognition to unlock is milestone G,
//  handled separately by FaceUnlockCoordinator (off by default).
//

import Foundation
import CoreGraphics
import Observation

struct RecognitionResult: Identifiable {
    let id = UUID()
    let name: String
    /// Similarity against the identity's averaged template.
    let centroidSimilarity: Float
    /// Similarity against the single closest individual sample — catches
    /// cases where averaging blurred together poses that shouldn't be
    /// blended. A match must clear the threshold on *both* measures.
    let maxSampleSimilarity: Float
    let isStale: Bool
}

/// One manually-tagged data point for threshold calibration: "this
/// similarity score came from a genuine match" or "from an impostor."
struct CalibrationSample: Identifiable {
    let id = UUID()
    let centroidSimilarity: Float
    let isGenuine: Bool
}

@Observable
@MainActor
final class FaceLabController {
    let camera = CameraManager()
    let store = FaceEnrollmentStore.shared
    let pipeline = FaceRecognitionPipeline()

    private(set) var detectedFaces: [DetectedFace] = []
    private(set) var currentResult: FaceRecognitionResult?

    /// Fed every frame a face is detected, live — same as
    /// `FaceUnlockCoordinator`'s scan loop, so this is exactly what the
    /// real unlock path would see, not a separately-tuned debug copy.
    private let livenessAnalyzer = LivenessAnalyzer()
    private(set) var currentLiveness = LivenessSnapshot.empty
    /// Diagnostics behind the flat-vs-3D cue (excess ratio, coherence, pair
    /// counts, yaw range) — the numbers that explain *why* that cue is
    /// reading what it reads, which the cue's own 0...1 level can't show.
    private(set) var currentGeometry = GeometryLivenessResult.empty
    /// The single most recent extracted frame — separate from the window
    /// `livenessAnalyzer` holds internally, which isn't itself inspectable.
    /// Exists so the debug view can show raw measurements (eye-aspect-ratio,
    /// device overlap, specular fraction) live, not just the derived cue
    /// levels — needed to tell "the threshold is wrong" from "the underlying
    /// measurement isn't moving at all," which isn't visible from the level
    /// alone.
    private(set) var lastLivenessFrame: LivenessFrame?

    /// Face Lab drives mode and tuning locally rather than reading
    /// `GlanceSettings`, so experimenting here can never silently change
    /// what actually unlocks the Mac. Heavy by default in the lab — the
    /// point of this tab is to watch the confirm cues, which Light mode
    /// short-circuits entirely.
    var livenessMode: LivenessMode = .heavy
    var livenessTuning = LivenessTuning.default
    var enabledLivenessCues: Set<LivenessCue> = Set(LivenessCue.allCases)

    func isLivenessCueEnabled(_ cue: LivenessCue) -> Bool {
        enabledLivenessCues.contains(cue)
    }

    func setLivenessCue(_ cue: LivenessCue, enabled: Bool) {
        if enabled {
            enabledLivenessCues.insert(cue)
        } else {
            enabledLivenessCues.remove(cue)
        }
    }

    /// Restarts just the liveness half without touching the camera or
    /// recognition — cue firing latches for a whole scan by design, so
    /// re-testing a spoof after one has been caught needs an explicit
    /// clear.
    func resetLiveness() {
        livenessAnalyzer.reset()
        currentLiveness = .empty
        currentGeometry = .empty
        log("Liveness cues reset.")
    }

    var enrollName: String = ""
    /// Raw cosine similarity cutoff (-1...1), the value ArcFace thresholds
    /// are conventionally quoted in (typical verification cutoffs sit
    /// around 0.28-0.40). Vision feature-print has no such standard, so
    /// this stays tunable regardless of which embedder is active — see the
    /// calibration harness for picking a value empirically.
    var threshold: Double = 0.6
    /// Minimum lead the best match must have over the runner-up once more
    /// than one identity is enrolled, so a close tie between two people
    /// doesn't produce a confident-looking single "best match."
    private let minMargin: Float = 0.05

    private(set) var recognitionResults: [RecognitionResult] = []
    private(set) var bestMatch: RecognitionResult?

    private(set) var logLines: [String] = []
    private(set) var sessionError: String?

    private var isProcessingFrame = false

    init() {
        observeFrames()
        livenessAnalyzer.modeProvider = { [weak self] in self?.livenessMode ?? .heavy }
        livenessAnalyzer.tuningProvider = { [weak self] in self?.livenessTuning ?? .default }
        livenessAnalyzer.enabledCuesProvider = { [weak self] in
            self?.enabledLivenessCues ?? Set(LivenessCue.allCases)
        }
        store.reloadIfUnlocked()
        if pipeline.usingFallbackEmbedder {
            log("ArcFace unavailable (\(pipeline.fallbackReason ?? "unknown reason")) — using Vision Feature Print instead.")
        } else {
            log("Using \(pipeline.embedder.name).")
        }
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
        currentResult = nil
        livenessAnalyzer.reset()
        currentLiveness = .empty
        currentGeometry = .empty
        lastLivenessFrame = nil
        log("Camera stopped.")
    }

    /// Face embeddings are encrypted under the same Touch-ID-gated session
    /// key as the stored Mac password (see SecureFaceStore) — this mirrors
    /// POCController.unlockSession() so Face Lab can be used standalone
    /// without switching to the Credentials tab first.
    func unlockSession() async {
        sessionError = nil
        do {
            try await Task.detached(priority: .userInitiated) {
                try SecureCredentialManager.unlockSession(reason: "Authenticate to use Face Lab")
            }.value
            store.reloadIfUnlocked()
            log("Session unlocked.")
        } catch {
            sessionError = error.localizedDescription
        }
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
        guard !isProcessingFrame, let cameraFrame = camera.currentFrame else { return }
        isProcessingFrame = true
        defer { isProcessingFrame = false }

        let pipeline = self.pipeline
        do {
            let (result, livenessFrame) = try await Task.detached(priority: .userInitiated) {
                let result = try pipeline.recognize(in: cameraFrame.image)
                let faceCrop = CameraManager.renderCrop(from: cameraFrame, imageRect: result.face.boundingBox)
                return (result, LivenessFeatureExtractor.extract(from: result, frame: cameraFrame.image, faceCrop: faceCrop))
            }.value
            detectedFaces = [result.face]
            currentResult = result
            lastLivenessFrame = livenessFrame
            currentLiveness = livenessAnalyzer.observe(livenessFrame)
            currentGeometry = livenessAnalyzer.lastGeometry
        } catch FaceRecognitionPipelineError.noFaceDetected {
            detectedFaces = []
            currentResult = nil
        } catch {
            detectedFaces = []
            currentResult = nil
            log("Detection error: \(error.localizedDescription)")
        }
    }

    // MARK: - Milestone E: enrollment

    func captureSample() {
        guard let result = currentResult else {
            log("No face detected — can't capture a sample.")
            return
        }
        let trimmedName = enrollName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            log("Enter a name before capturing a sample.")
            return
        }
        do {
            try store.addSample(
                name: trimmedName,
                embedding: result.embedding,
                embedder: pipeline.embedder,
                quality: result.quality
            )
            log("Captured sample for \"\(trimmedName)\" (\(result.embedding.count)-dim, \(result.alignmentTier.rawValue), quality \(Self.qualityLabel(result.quality))).")
        } catch {
            log("Couldn't save sample: \(error.localizedDescription)")
        }
    }

    func deleteIdentity(_ identity: FaceIdentity) {
        do {
            try store.delete(identity)
            log("Deleted \"\(identity.name)\".")
        } catch {
            log("Couldn't delete: \(error.localizedDescription)")
        }
    }

    // MARK: - Multi-identity enrollment
    //
    // Prototyped here ahead of the Your Face settings tab: the store, the
    // pipeline's `bestMatch` margin, and the guided flow all handle N
    // identities already — only the UI was single-identity.

    /// Counts only the red band of `FaceSample.qualityTier`, so this debug
    /// list and the Your Face page's tick strip always agree about what
    /// "low" means. The bands sit well above `OnboardingController`'s 0.2
    /// accept-floor, which is a *gate* applied during capture: no guided
    /// sample can be below it, so a 0.2 cutoff would always report zero.
    /// Samples with no score at all count as unrated, never as low.
    func lowQualityCount(in identity: FaceIdentity) -> Int {
        identity.samples.filter { $0.qualityTier == .poor }.count
    }

    /// Face Lab and the onboarding flow each own a separate `CameraManager`
    /// pointed at the same physical device — stopping ours first avoids
    /// handing it to two live sessions with different configurations.
    func startFullOnboarding() {
        camera.stop()
        log("Starting the full onboarding flow.")
        OnboardingController.startFlow()
    }

    func startAddIdentity() {
        camera.stop()
        log("Starting guided enrollment for a new identity.")
        OnboardingController.startAddIdentity()
    }

    func startRecapture(of identity: FaceIdentity) {
        camera.stop()
        log("Starting guided re-capture of \"\(identity.name)\".")
        OnboardingController.startRecapture(of: identity)
    }

    static func qualityLabel(_ quality: Float?) -> String {
        guard let quality else { return "—" }
        return String(format: "%.0f%%", quality * 100)
    }

    // MARK: - Milestone F: recognition

    func recognize() {
        guard let result = currentResult else {
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

        let embedder = pipeline.embedder
        let scored = pipeline.score(result.embedding, against: store.identities)
        recognitionResults = scored.map { s in
            RecognitionResult(
                name: s.identity.name,
                centroidSimilarity: s.centroidSimilarity,
                maxSampleSimilarity: s.maxSampleSimilarity,
                isStale: s.identity.isStale(comparedTo: embedder)
            )
        }

        let matched = pipeline.bestMatch(in: scored, threshold: Float(threshold), minMargin: minMargin)
        bestMatch = matched.map {
            RecognitionResult(name: $0.identity.name, centroidSimilarity: $0.centroidSimilarity, maxSampleSimilarity: $0.maxSampleSimilarity, isStale: false)
        }

        if let best = scored.first {
            let verdict = (bestMatch != nil) ? "MATCH" : "no match"
            let staleNote = best.identity.isStale(comparedTo: embedder) ? " [STALE — re-enroll under current model]" : ""
            log("Recognize: best = \(best.identity.name) centroid=\(String(format: "%.3f", best.centroidSimilarity)) max=\(String(format: "%.3f", best.maxSampleSimilarity)) -> \(verdict)\(staleNote)")
        }
    }

    // MARK: - Threshold calibration

    /// Tagged similarity scores collected during this session — the actual
    /// data a threshold should be picked from, rather than guessed. Record
    /// genuine samples across lighting/pose/expression, and impostor
    /// samples against a different person, then look at where the two
    /// distributions land relative to each other.
    private(set) var calibrationSamples: [CalibrationSample] = []

    /// Tags the most recent `recognize()` result's top score as genuine or
    /// impostor. Uses centroid similarity, matching what the threshold
    /// slider actually gates on.
    func recordCalibrationSample(isGenuine: Bool) {
        guard let top = recognitionResults.first else {
            log("Nothing to record — run Identify first.")
            return
        }
        calibrationSamples.append(CalibrationSample(centroidSimilarity: top.centroidSimilarity, isGenuine: isGenuine))
        log("Calibration: recorded \(isGenuine ? "genuine" : "impostor") sample at \(String(format: "%.3f", top.centroidSimilarity)).")
    }

    func clearCalibrationSamples() {
        calibrationSamples.removeAll()
    }

    /// Midpoint between the lowest genuine score and the highest impostor
    /// score — the standard "split the gap" pick once you have both
    /// distributions. Nil until at least one of each has been recorded.
    var suggestedThreshold: Float? {
        let genuine = calibrationSamples.filter(\.isGenuine).map(\.centroidSimilarity)
        let impostor = calibrationSamples.filter { !$0.isGenuine }.map(\.centroidSimilarity)
        guard let minGenuine = genuine.min(), let maxImpostor = impostor.max() else { return nil }
        return (minGenuine + maxImpostor) / 2
    }

    /// True if any impostor score is >= any genuine score — meaning no
    /// single threshold perfectly separates the two groups yet, a real
    /// possibility worth surfacing rather than hiding behind a suggested
    /// midpoint that would still misclassify some of the recorded samples.
    var calibrationDistributionsOverlap: Bool {
        let genuine = calibrationSamples.filter(\.isGenuine).map(\.centroidSimilarity)
        let impostor = calibrationSamples.filter { !$0.isGenuine }.map(\.centroidSimilarity)
        guard let minGenuine = genuine.min(), let maxImpostor = impostor.max() else { return false }
        return maxImpostor >= minGenuine
    }

    private func log(_ message: String) {
        let timestamp = Date().formatted(date: .omitted, time: .standard)
        logLines.append("[\(timestamp)] \(message)")
        if logLines.count > 200 {
            logLines.removeFirst(logLines.count - 200)
        }
    }
}
