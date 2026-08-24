//
//  FaceLabView.swift
//  glance
//
//  Debug console: camera preview, face detection + alignment, enrollment,
//  and recognition — all in one tab, independent of the credential/unlock
//  POC in the other tab.
//

import SwiftUI
import Charts

struct FaceLabView: View {
    /// Injected from AppEnvironment rather than created here, so the
    /// Recognition settings page's "use Face Lab's suggested threshold"
    /// button reads calibration data from this same instance instead of a
    /// second, independently-empty FaceLabController.
    @Bindable var controller: FaceLabController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Face Lab — On-Device Face Recognition (Debug)")
                        .font(.headline)
                    Spacer()
                    Button("Preview ✓") {
                        NotchOverlayController.shared.present()
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            NotchOverlayController.shared.finish(success: true)
                        }
                    }
                    Button("Preview ✗") {
                        NotchOverlayController.shared.present(onRetry: {
                            Task {
                                try? await Task.sleep(for: .seconds(1.5))
                                NotchOverlayController.shared.finish(success: false)
                            }
                        })
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            NotchOverlayController.shared.finish(success: false)
                        }
                    }
                    Button("Start Onboarding") {
                        controller.startFullOnboarding()
                    }
                    .disabled(enrollmentFlowIsRunning)
                }

                modelStatusSection
                sessionLockSection
                previewSection
                detectionSection
                livenessSection
                enrollSection
                identitiesSection
                recognizeSection
                calibrationSection
                logSection
            }
            .padding(20)
        }
        // No minWidth/minHeight: those sized the old standalone debug
        // window. This view is now hosted inside the Settings window's
        // narrower content pane, where a 560pt floor just clipped the right
        // edge instead of letting the content reflow.
        .onDisappear {
            controller.stop()
        }
        // Guided enrollment runs in the notch, entirely outside this
        // window's view hierarchy, so nothing else would prompt a re-read
        // once it closes — and its Touch ID prompt is often what unlocks
        // the session in the first place. Same trick YourFaceSettingsPage
        // uses for exactly this reason.
        .onChange(of: NotchOverlayController.shared.phase) { _, newPhase in
            guard newPhase == .closed else { return }
            controller.store.reloadIfUnlocked()
        }
    }

    /// True while the notch is already hosting an onboarding flow. It's a
    /// single shared panel, so starting a second one would swap the content
    /// out from under the first mid-capture.
    private var enrollmentFlowIsRunning: Bool {
        NotchOverlayController.shared.phase == .onboarding
    }

    // MARK: - Which embedder is active

    private var modelStatusSection: some View {
        HStack {
            Circle()
                .fill(controller.pipeline.usingFallbackEmbedder ? .orange : .green)
                .frame(width: 8, height: 8)
            Text("Embedder: \(controller.pipeline.embedder.name)")
                .font(.caption)
            if controller.pipeline.usingFallbackEmbedder {
                Text("(ArcFace unavailable — see log)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
    }

    // MARK: - Session lock (face data is encrypted under the session key)

    private var sessionLockSection: some View {
        Group {
            if controller.store.isLocked {
                HStack {
                    Circle().fill(.red).frame(width: 8, height: 8)
                    Text("Session locked — enrolled faces are encrypted and can't be read or saved yet.")
                        .font(.caption)
                    Spacer()
                    Button("Unlock") {
                        Task { await controller.unlockSession() }
                    }
                }
                if let error = controller.sessionError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
    }

    // MARK: - Milestone A: preview

    private var previewSection: some View {
        GroupBox("Camera Preview") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Circle()
                        .fill(controller.camera.isRunning ? .green : .gray)
                        .frame(width: 10, height: 10)
                    Text(controller.camera.isRunning ? "Running" : "Stopped")
                    Spacer()
                    Button(controller.camera.isRunning ? "Stop" : "Start") {
                        if controller.camera.isRunning {
                            controller.stop()
                        } else {
                            Task { await controller.start() }
                        }
                    }
                }

                if let error = controller.camera.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }

                CameraPreviewView(session: controller.camera.session, faces: controller.detectedFaces)
                    .frame(height: 300)
                    .background(Color.black.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Milestones B/C/D: detection + alignment + embedding

    private var detectionSection: some View {
        GroupBox("Detection") {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Faces detected: \(controller.detectedFaces.count)")
                    if let quality = controller.currentResult?.quality {
                        Text("Capture quality: \(String(format: "%.0f%%", quality * 100))")
                    } else {
                        Text("Capture quality: —")
                            .foregroundStyle(.secondary)
                    }
                    if let result = controller.currentResult {
                        Text("Alignment: \(result.alignmentTier.rawValue)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Embedding: \(result.embedding.count) numbers")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        // Calibration aid for onboarding's pose gating — turn/tilt
                        // your head and watch these to confirm which sign means
                        // which direction before trusting OnboardingController's
                        // yaw/pitch bands (see its poseMatches comment).
                        Text("Yaw: \(yawPitchString(result.face.yaw))  Pitch: \(yawPitchString(result.face.pitch))")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(spacing: 4) {
                    Text("Aligned input").font(.caption).foregroundStyle(.secondary)
                    if let aligned = controller.currentResult?.alignedImage {
                        Image(aligned, scale: 1, orientation: .up, label: Text("Aligned face"))
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.gray.opacity(0.15))
                            .frame(width: 96, height: 96)
                            .overlay(Text("No face").font(.caption2).foregroundStyle(.secondary))
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Liveness

    /// One section for all five cues, split by role rather than by which
    /// checker they used to live in. The old two-section layout (motion &
    /// geometry vs. spoof artifacts) is gone along with the signals that
    /// justified it — what matters now is only whether a cue argues for a
    /// spoof or for a real face, since either one firing decides the scan
    /// on its own.
    private var livenessSection: some View {
        GroupBox("Liveness") {
            VStack(alignment: .leading, spacing: 12) {
                decisionStrip

                Picker("Mode", selection: $controller.livenessMode) {
                    ForEach(LivenessMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)

                Text(controller.livenessMode == .light
                     ? "Light: only the deny cues run. Anything not actively rejected is treated as live."
                     : "Heavy: a deny cue fails the scan; at least one confirm cue must fire before it can pass.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Divider()

                cueGroup(
                    title: "Deny — evidence of a spoof",
                    caption: "Either one firing fails face unlock outright, and overrides any confirmation.",
                    cues: LivenessCue.allCases.filter { $0.role == .deny }
                )

                cueGroup(
                    title: "Confirm — evidence of a real face",
                    caption: "Any one firing passes liveness. None firing is not a failure — the scan just keeps looking.",
                    cues: LivenessCue.allCases.filter { $0.role == .confirm }
                )

                rawMeasurementsBlock
                geometryDiagnosticsBlock

                HStack {
                    Button("Reset cues") { controller.resetLiveness() }
                    Text("Cue firing latches for the whole scan — reset to re-test.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var decisionStrip: some View {
        let decision = controller.currentLiveness.decision
        let (color, label): (Color, String) = {
            switch decision {
            case .pending:
                return (.secondary, "Pending — nothing decided yet")
            case .confirmed(let cue):
                return (.green, cue.map { "Live — confirmed by \($0.title)" } ?? "Live — auto-confirmed (Light mode)")
            case .denied(let cue):
                return (.red, "Spoof — denied by \(cue.title)")
            }
        }()
        return HStack(spacing: 10) {
            Circle().fill(color).frame(width: 10, height: 10)
            Text(label).font(.system(.body, design: .monospaced))
            Spacer()
            Text("\(controller.currentLiveness.frameCount) frames")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func cueGroup(title: String, caption: String, cues: [LivenessCue]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold))
            ForEach(cues) { cue in
                cueRow(cue)
            }
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 2)
        }
    }

    /// Level bar plus a fire counter. The counter is the part that matters
    /// now: a cue's instantaneous level is only interesting insofar as it
    /// crosses the fire threshold on enough frames, so both are shown side
    /// by side rather than the level alone.
    private func cueRow(_ cue: LivenessCue) -> some View {
        let state = controller.currentLiveness.state(for: cue)
        let isEnabled = controller.isLivenessCueEnabled(cue)
        let threshold = controller.livenessTuning.level(for: cue)
        let framesNeeded = controller.livenessTuning.frames(for: cue)
        let hasEvidence = state.reading.confidence > 0

        return HStack(spacing: 8) {
            Toggle("", isOn: Binding(
                get: { controller.isLivenessCueEnabled(cue) },
                set: { controller.setLivenessCue(cue, enabled: $0) }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .help(cue.explanation)

            Text(cue.title)
                .font(.caption)
                .frame(width: 110, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.gray.opacity(0.15))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(hasEvidence ? (cue.role == .deny ? Color.orange : Color.accentColor) : Color.gray.opacity(0.3))
                        .frame(width: geometry.size.width * CGFloat(state.reading.level))
                    // Where this cue starts counting frames.
                    Rectangle()
                        .fill(Color.primary.opacity(0.45))
                        .frame(width: 1)
                        .offset(x: geometry.size.width * CGFloat(threshold))
                }
            }
            .frame(height: 8)

            Text(hasEvidence ? String(format: "%.0f%%", state.reading.level * 100) : "—")
                .font(.caption.monospacedDigit())
                .frame(width: 36, alignment: .trailing)

            Text("\(state.framesCounted)/\(framesNeeded)")
                .font(.caption2.monospacedDigit())
                .frame(width: 40, alignment: .trailing)
                .foregroundStyle(.secondary)

            Text(state.hasFired ? "FIRED" : "")
                .font(.caption2.weight(.bold))
                .foregroundStyle(cue.role == .deny ? Color.red : Color.green)
                .frame(width: 44, alignment: .leading)
        }
        .opacity(isEnabled ? 1 : 0.45)
    }

    /// The actual measurements each cue level is derived from — how to tell
    /// "the threshold is wrong" from "the underlying number isn't moving."
    private var rawMeasurementsBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let frame = controller.lastLivenessFrame {
                Text("Left EAR: \(ratioString(frame.leftEyeAspectRatio))  Right EAR: \(ratioString(frame.rightEyeAspectRatio))  Nose offset: \(ratioString(frame.noseOffsetRatio))")
                Text("Device overlap: \(percentString(frame.deviceOverlapFraction))")
                if let glare = frame.glare {
                    Text("Specular: \(String(format: "%.4f", glare.specularFraction))  Cluster: \(String(format: "%.2f", glare.specularClusterRatio))  Crop: \(Int(glare.cropPixelWidth))px")
                } else {
                    Text("Specular: — (no native-resolution crop this frame)")
                }
            } else {
                Text("No liveness frame yet.")
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }

    private var geometryDiagnosticsBlock: some View {
        let geo = controller.currentGeometry
        return VStack(alignment: .leading, spacing: 6) {
            Text("Flat vs 3D diagnostics")
                .font(.caption.weight(.semibold))
            Text("Landmarks: \(geo.validLandmarkCount)   Pairs: \(geo.pairsAnalyzed)   Rejected: \(geo.rejectedPairCount)")
            Text("Fit residual: \(ratioString(geo.medianFitResidual))  Probe residual: \(ratioString(geo.medianProbeResidual))  Excess: \(ratioString(geo.excessRatio))")
            Text("Coherence: \(ratioString(geo.coherence))  Motion: \(ratioString(geo.motionMagnitude))")
            if !geo.diagnosticRatios.isEmpty {
                Text(geo.diagnosticRatios.keys.sorted().map { key in
                    "\(key) \(ratioString(geo.diagnosticRatios[key]))"
                }.joined(separator: "  "))
            }
            if geo.planarConfidence == 0 {
                Text("Abstaining — not enough head rotation to tell a plane from a still 3D face.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .padding(.top, 4)
    }

    private func ratioString(_ value: CGFloat?) -> String {
        guard let value else { return "—" }
        return String(format: "%+.3f", value)
    }

    private func percentString(_ value: CGFloat?) -> String {
        guard let value else { return "—" }
        return String(format: "%.0f%%", value * 100)
    }

    // MARK: - Milestone E: enrollment

    private var enrollSection: some View {
        GroupBox("Enroll") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField("Name", text: $controller.enrollName)
                        .textFieldStyle(.roundedBorder)
                    Button("Capture Sample") {
                        controller.captureSample()
                    }
                    .disabled(controller.currentResult == nil || controller.store.isLocked)
                }

                if controller.store.identities.isEmpty {
                    Text(controller.store.isLocked ? "Unlock the session to view enrolled identities." : "No identities enrolled yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.store.identities) { identity in
                        HStack {
                            Text(identity.name)
                            Text("\(identity.samples.count) sample\(identity.samples.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if identity.isStale(comparedTo: controller.pipeline.embedder) {
                                Text("stale")
                                    .font(.caption2.bold())
                                    .foregroundStyle(.orange)
                            }
                            Spacer()
                            Button(role: .destructive) {
                                controller.deleteIdentity(identity)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Multi-identity enrollment
    //
    // A prototype of what the "Your Face" settings tab will show once it
    // stops reading `identities.first`. Everything below the UI already
    // supported several people: the store keeps an array, and
    // `bestMatch`'s minMargin gate only engages past one identity.

    private var identitiesSection: some View {
        GroupBox("Identities") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("\(controller.store.identities.count) enrolled")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Identity") {
                        controller.startAddIdentity()
                    }
                    .disabled(controller.store.isLocked || enrollmentFlowIsRunning)
                }

                if controller.store.identities.isEmpty {
                    Text(controller.store.isLocked
                         ? "Unlock the session to view enrolled identities."
                         : "No identities enrolled yet — run the guided nine-pose capture with Add Identity.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.store.identities) { identity in
                        IdentityRow(
                            identity: identity,
                            isStale: identity.isStale(comparedTo: controller.pipeline.embedder),
                            lowQualityCount: controller.lowQualityCount(in: identity),
                            canStartFlow: !enrollmentFlowIsRunning,
                            recapture: { controller.startRecapture(of: identity) },
                            delete: { controller.deleteIdentity(identity) }
                        )
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Milestone F: recognition

    private var recognizeSection: some View {
        GroupBox("Recognize") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button("Identify") {
                        controller.recognize()
                    }
                    .disabled(controller.currentResult == nil || controller.store.identities.isEmpty)

                    Spacer()

                    Text("Threshold: \(String(format: "%.2f", controller.threshold))")
                        .font(.caption)
                    Slider(value: $controller.threshold, in: -1...1)
                        .frame(width: 160)
                }

                if let best = controller.bestMatch {
                    HStack {
                        Circle().fill(.green).frame(width: 10, height: 10)
                        Text("Best match: \(best.name) — centroid \(String(format: "%.3f", best.centroidSimilarity)), max \(String(format: "%.3f", best.maxSampleSimilarity))")
                        Text("MATCH").font(.caption.bold()).foregroundStyle(.green)
                    }
                } else if let first = controller.recognitionResults.first {
                    HStack {
                        Circle().fill(.red).frame(width: 10, height: 10)
                        Text("Closest: \(first.name) — centroid \(String(format: "%.3f", first.centroidSimilarity)), max \(String(format: "%.3f", first.maxSampleSimilarity))")
                        Text("NO MATCH").font(.caption.bold()).foregroundStyle(.red)
                    }
                }

                if !controller.recognitionResults.isEmpty {
                    Divider()
                    ForEach(controller.recognitionResults) { result in
                        HStack {
                            Text(result.name)
                            if result.isStale {
                                Text("stale").font(.caption2.bold()).foregroundStyle(.orange)
                            }
                            Spacer()
                            Text("centroid \(String(format: "%.3f", result.centroidSimilarity))")
                                .foregroundStyle(.secondary)
                            Text("max \(String(format: "%.3f", result.maxSampleSimilarity))")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Threshold calibration

    private var calibrationSection: some View {
        GroupBox("Threshold Calibration") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Run Identify, then tag whether that was really you or someone else — do this across lighting, angle, and expression, and again with a different person, to see where the two score distributions actually fall.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Button("Mark Genuine (this is me)") {
                        controller.recordCalibrationSample(isGenuine: true)
                    }
                    Button("Mark Impostor (not me)") {
                        controller.recordCalibrationSample(isGenuine: false)
                    }
                    .disabled(controller.recognitionResults.isEmpty)
                    Spacer()
                    Button("Clear", role: .destructive) {
                        controller.clearCalibrationSamples()
                    }
                    .disabled(controller.calibrationSamples.isEmpty)
                }
                .disabled(controller.recognitionResults.isEmpty && controller.calibrationSamples.isEmpty)

                if !controller.calibrationSamples.isEmpty {
                    Chart {
                        ForEach(controller.calibrationSamples) { sample in
                            PointMark(
                                x: .value("Similarity", sample.centroidSimilarity),
                                y: .value("Type", sample.isGenuine ? "Genuine" : "Impostor")
                            )
                            .foregroundStyle(sample.isGenuine ? Color.green : Color.red)
                        }
                        RuleMark(x: .value("Threshold", controller.threshold))
                            .foregroundStyle(.blue)
                            .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 4]))
                    }
                    .chartXScale(domain: -1...1)
                    .frame(height: 100)

                    if let suggested = controller.suggestedThreshold {
                        HStack {
                            Text("Suggested threshold: \(String(format: "%.3f", suggested))")
                                .font(.caption)
                            Button("Use it") {
                                controller.threshold = Double(suggested)
                            }
                            if controller.calibrationDistributionsOverlap {
                                Text("Distributions overlap — no single cutoff perfectly separates these samples yet.")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    } else {
                        Text("Record at least one genuine and one impostor sample to get a suggestion.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    // MARK: - Debug log

    private var logSection: some View {
        GroupBox("Log") {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(controller.logLines.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 120)
        }
    }

    private func yawPitchString(_ value: Float?) -> String {
        guard let value else { return "—" }
        return String(format: "%+.2f", value)
    }
}

/// One enrolled person: a summary line, the actions that apply to them, and
/// a disclosure listing every stored sample with the capture quality that
/// used to be shown live and then thrown away.
private struct IdentityRow: View {
    let identity: FaceIdentity
    let isStale: Bool
    let lowQualityCount: Int
    let canStartFlow: Bool
    let recapture: () -> Void
    let delete: () -> Void

    private var posesCaptured: Int {
        Set(identity.samples.compactMap(\.pose)).count
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(identity.samples.enumerated()), id: \.offset) { index, sample in
                    HStack(spacing: 8) {
                        Text(String(format: "%2d", index + 1))
                            .foregroundStyle(.tertiary)
                        Text(sample.pose ?? "untagged")
                            .frame(width: 90, alignment: .leading)
                        Text(FaceLabController.qualityLabel(sample.quality))
                            .frame(width: 44, alignment: .trailing)
                            .foregroundStyle(isLow(sample) ? .orange : .primary)
                        Text(sample.capturedAt.formatted(date: .omitted, time: .standard))
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .font(.caption.monospaced())
                }
            }
            .padding(.top, 4)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(identity.name).bold()
                    if isStale {
                        Text("stale")
                            .font(.caption2.bold())
                            .foregroundStyle(.orange)
                    }
                    Spacer()
                    Button("Recapture", action: recapture)
                        .disabled(!canStartFlow)
                    Button(role: .destructive, action: delete) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.plain)
                }

                Text("\(posesCaptured)/9 poses · \(identity.samples.count) samples · enrolled \(identity.createdAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if lowQualityCount > 0 {
                    Text("\(lowQualityCount) of \(identity.samples.count) samples are low quality")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    private func isLow(_ sample: FaceSample) -> Bool {
        sample.qualityTier == .poor
    }
}

#Preview {
    FaceLabView(controller: FaceLabController())
}
