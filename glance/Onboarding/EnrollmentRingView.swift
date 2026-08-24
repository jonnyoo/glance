//
//  EnrollmentRingView.swift
//  glance
//
//  The tick ring around the camera preview during guided enrollment. 80
//  ticks (10 per 45deg sector) tile the full circle; a sector's ticks grow
//  longer and turn accent-blue once that direction has been captured.
//  Center has no sector of its own — capturing it pulses every tick
//  briefly instead (see `centerPulseTick` on OnboardingController).
//  When enrollment finishes, the ticks merge into a solid accent loop
//  while the checkmark draws.
//

import SwiftUI

struct EnrollmentRingView: View {
    let controller: OnboardingController

    @State private var pulseActive = false

    private var diameter: CGFloat { OnboardingMetrics.tickRingOuterDiameter }
    private var radius: CGFloat { diameter / 2 }
    private var isComplete: Bool { controller.enrollmentComplete }

    var body: some View {
        ZStack {
            ForEach(0..<OnboardingMetrics.tickCount, id: \.self) { index in
                Capsule()
                    .fill(color(for: index))
                    .frame(width: width(for: index), height: length(for: index))
                    // Inner tip anchored at the ring radius; growing `length`
                    // extends the outer tip further out, not inward.
                    .offset(y: -(radius + length(for: index) / 2))
                    .rotationEffect(.degrees(angle(for: index)))
                    .opacity(isComplete ? 0 : 1)
                    .animation(
                        .easeOut(duration: 0.3).delay(Double(index % OnboardingMetrics.ticksPerSector) * OnboardingMetrics.tickStagger),
                        value: isLit(index)
                    )
                    .animation(.easeOut(duration: 0.22), value: pulseActive)
                    .animation(
                        .easeInOut(duration: 0.45).delay(Double(index) * 0.004),
                        value: isComplete
                    )
            }

            // Frame diameter is solved to keep the ring's outer edge fixed
            // at `diameter/2 + tickLengthLit` — exactly where the lit
            // ticks' outer tips sit — regardless of `completionRingWidth`,
            // so a thinner ring still reads as "the ticks settled into
            // this," not as a smaller circle floating inside them.
            Circle()
                .stroke(GlanceTheme.accent, lineWidth: OnboardingMetrics.completionRingWidth)
                .frame(
                    width: diameter + 2 * OnboardingMetrics.tickLengthLit - OnboardingMetrics.completionRingWidth,
                    height: diameter + 2 * OnboardingMetrics.tickLengthLit - OnboardingMetrics.completionRingWidth
                )
                .opacity(isComplete ? 1 : 0)
                .scaleEffect(isComplete ? 1 : 0.92)
                .animation(.easeInOut(duration: 0.45), value: isComplete)
        }
        .frame(width: diameter, height: diameter)
        .onChange(of: controller.centerPulseTick) { _, _ in
            triggerPulse()
        }
    }

    private func angle(for index: Int) -> Double {
        Double(index) * (360.0 / Double(OnboardingMetrics.tickCount))
    }

    /// Which of the 8 directional poses a tick's angle falls under —
    /// buckets each tick into the nearest 45deg sector.
    private func sectorPose(for index: Int) -> EnrollmentPose? {
        let raw = Int((angle(for: index) / 45.0).rounded()) % 8
        let sectorAngle = Double(raw) * 45
        return EnrollmentPose.allCases.first { $0.compassAngle == sectorAngle }
    }

    private func isLit(_ index: Int) -> Bool {
        if isComplete { return true }
        guard let pose = sectorPose(for: index) else { return false }
        return controller.capturedPoses.contains(pose)
    }

    private func length(for index: Int) -> CGFloat {
        (isLit(index) || pulseActive) ? OnboardingMetrics.tickLengthLit : OnboardingMetrics.tickLengthUnlit
    }

    private func width(for index: Int) -> CGFloat {
        isComplete ? OnboardingMetrics.tickWidthComplete : OnboardingMetrics.tickWidth
    }

    private func color(for index: Int) -> Color {
        (isLit(index) || isComplete) ? GlanceTheme.accent : .white
    }

    private func triggerPulse() {
        Task {
            pulseActive = true
            try? await Task.sleep(for: .milliseconds(220))
            pulseActive = false
        }
    }
}
