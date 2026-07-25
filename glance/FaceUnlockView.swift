//
//  FaceUnlockView.swift
//  glance
//
//  The one opt-in switch that actually connects face recognition to
//  unlock. Off by default — see FaceUnlockCoordinator.
//

import SwiftUI

struct FaceUnlockView: View {
    @State private var coordinator: FaceUnlockCoordinator

    init(pocController: POCController) {
        _coordinator = State(initialValue: FaceUnlockCoordinator(pocController: pocController))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Face Unlock").font(.headline)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Unlock with Glance", isOn: $coordinator.isEnabled)
                        .font(.title3)
                    Text("When your Mac is locked, Glance looks for your enrolled face and, on a confident, live match, types your stored password automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            GroupBox("Important limitation") {
                Text("This Mac's webcam has no depth sensor. Glance can tell a live face from a printed photo, but it cannot reliably tell a live face from a video or photo shown on another screen. A successful spoof would type your real Mac password. Only enable this if you're comfortable with that tradeoff.")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.vertical, 4)
            }

            GroupBox("Status") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Circle()
                            .fill(coordinator.isEnabled ? .green : .gray)
                            .frame(width: 10, height: 10)
                        Text(coordinator.isEnabled ? "Armed" : "Off")
                    }
                    Text(coordinator.statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let outcome = coordinator.lastOutcome {
                        Text("Last attempt: \(outcome)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox("Match threshold") {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Threshold: \(String(format: "%.2f", coordinator.matchThreshold))")
                            .font(.caption)
                        Slider(
                            value: Binding(
                                get: { Double(coordinator.matchThreshold) },
                                set: { coordinator.matchThreshold = Float($0) }
                            ),
                            in: -1...1
                        )
                    }
                    Text("Deliberately independent from Face Lab's threshold — tune there first, then set the same value here so testing never silently changes the real unlock gate.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }

            Spacer()
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 560)
    }
}
