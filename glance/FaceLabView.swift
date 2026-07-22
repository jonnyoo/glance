//
//  FaceLabView.swift
//  glance
//
//  Debug console for milestones A-F: camera preview, face detection, crop
//  preview, enrollment, and recognition — all in one tab, independent of the
//  credential/unlock POC in the other tab.
//

import SwiftUI

struct FaceLabView: View {
    @State private var controller = FaceLabController()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Face Lab — On-Device Face Recognition (Debug)")
                    .font(.headline)

                previewSection
                detectionSection
                enrollSection
                recognizeSection
                logSection
            }
            .padding(20)
        }
        .frame(minWidth: 560, minHeight: 700)
        .onDisappear {
            controller.stop()
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

    // MARK: - Milestones B/C: detection + crop

    private var detectionSection: some View {
        GroupBox("Detection") {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Faces detected: \(controller.detectedFaces.count)")
                    if let quality = controller.faceQuality {
                        Text("Capture quality: \(String(format: "%.0f%%", quality * 100))")
                    } else {
                        Text("Capture quality: —")
                            .foregroundStyle(.secondary)
                    }
                    if let embedding = controller.currentEmbedding {
                        Text("Embedding: \(embedding.count) numbers")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                VStack(spacing: 4) {
                    Text("Cropped face").font(.caption).foregroundStyle(.secondary)
                    if let crop = controller.croppedFace {
                        Image(crop, scale: 1, orientation: .up, label: Text("Cropped face"))
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
                    .disabled(controller.currentEmbedding == nil)
                }

                if controller.store.identities.isEmpty {
                    Text("No identities enrolled yet.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(controller.store.identities) { identity in
                        HStack {
                            Text(identity.name)
                            Text("\(identity.samples.count) sample\(identity.samples.count == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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
                    .disabled(controller.currentEmbedding == nil || controller.store.identities.isEmpty)

                    Spacer()

                    Text("Threshold: \(Int(controller.threshold))%")
                        .font(.caption)
                    Slider(value: $controller.threshold, in: 0...100)
                        .frame(width: 160)
                }

                if let best = controller.bestMatch {
                    HStack {
                        Circle()
                            .fill(best.similarityPercent >= controller.threshold ? .green : .red)
                            .frame(width: 10, height: 10)
                        Text("Best match: \(best.name) — \(String(format: "%.1f", best.similarityPercent))%")
                        Text(best.similarityPercent >= controller.threshold ? "MATCH" : "NO MATCH")
                            .font(.caption.bold())
                            .foregroundStyle(best.similarityPercent >= controller.threshold ? .green : .red)
                    }
                }

                if !controller.recognitionResults.isEmpty {
                    Divider()
                    ForEach(controller.recognitionResults) { result in
                        HStack {
                            Text(result.name)
                            Spacer()
                            Text("\(String(format: "%.1f", result.similarityPercent))%")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
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
}

#Preview {
    FaceLabView()
}
