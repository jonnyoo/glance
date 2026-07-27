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
    @State private var controller = FaceLabController()

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
                        OnboardingController.startFlow()
                    }
                }

                modelStatusSection
                sessionLockSection
                previewSection
                detectionSection
                enrollSection
                recognizeSection
                calibrationSection
                logSection
            }
            .padding(20)
        }
        .frame(minWidth: 560, minHeight: 700)
        .onDisappear {
            controller.stop()
        }
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

#Preview {
    FaceLabView()
}
