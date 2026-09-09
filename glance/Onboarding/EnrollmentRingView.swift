//
//  EnrollmentRingView.swift
//  glance
//
//  80 ticks tile the circle in 45deg sectors that light up once captured; center has no
//  sector of its own and pulses every tick instead (see `centerPulseTick`). A short band
//  also tracks where the head is currently turned.
//

import SwiftUI

struct EnrollmentRingView: View {
    let controller: OnboardingController

    @State private var pulseActive = false

    private var diameter: CGFloat { OnboardingMetrics.tickRingOuterDiameter }
    private var radius: CGFloat { diameter / 2 }
    private var isComplete: Bool { controller.enrollmentComplete }

    var body: some View {
        let turn = controller.headTurn
        ZStack {
            ForEach(0..<OnboardingMetrics.tickCount, id: \.self) { index in
                let intensity = turnIntensity(for: index, turn: turn)
                let length = length(for: index, intensity: intensity)
                Capsule()
                    .fill(color(for: index, intensity: intensity))
                    .frame(width: width(for: index), height: length)
                    // Inner tip anchored at the ring radius; growing `length` extends outward, not inward.
                    .offset(y: -(radius + length / 2))
                    .rotationEffect(.degrees(angle(for: index)))
                    .opacity(isComplete ? 0 : 1)
                    .animation(
                        .easeOut(duration: 0.3).delay(Double(index % OnboardingMetrics.ticksPerSector) * OnboardingMetrics.tickStagger),
                        value: isLit(index)
                    )
                    .animation(.easeOut(duration: 0.22), value: pulseActive)
                    // Undelayed — tracks a live head, so it has to keep up.
                    .animation(.easeOut(duration: 0.15), value: intensity)
                    .animation(
                        .easeInOut(duration: 0.45).delay(Double(index) * 0.004),
                        value: isComplete
                    )
            }

            // Sized to sit just inside the lit ticks' outer tips, so the ring reads a hair
            // smaller once the ticks vanish and it's left on its own.
            Circle()
                .stroke(GlanceTheme.accent, lineWidth: OnboardingMetrics.completionRingWidth)
                .frame(
                    width: diameter + 2 * (OnboardingMetrics.tickLengthLit - OnboardingMetrics.completionRingRadiusInset) - OnboardingMetrics.completionRingWidth,
                    height: diameter + 2 * (OnboardingMetrics.tickLengthLit - OnboardingMetrics.completionRingRadiusInset) - OnboardingMetrics.completionRingWidth
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

    private func length(for index: Int, intensity: Double) -> CGFloat {
        if isLit(index) || pulseActive { return OnboardingMetrics.tickLengthLit }
        return OnboardingMetrics.tickLengthUnlit + OnboardingMetrics.turnIndicatorLengthBoost * intensity
    }

    private func width(for index: Int) -> CGFloat {
        isComplete ? OnboardingMetrics.tickWidthComplete : OnboardingMetrics.tickWidth
    }

    private func color(for index: Int, intensity: Double) -> Color {
        if isLit(index) || isComplete { return GlanceTheme.accent }
        return GlanceTheme.whiteToAccent(intensity)
    }

    /// Drives a tick's colour and length: peaks where the turn points, fading out half a
    /// span to either side. Tracks the real angle, not the 45deg sectors.
    private func turnIntensity(for index: Int, turn: OnboardingController.HeadTurn?) -> Double {
        guard let turn, !isComplete, !isLit(index) else { return 0 }

        var delta = abs(angle(for: index) - turn.angle)
        if delta > 180 { delta = 360 - delta }

        let degreesPerTick = 360.0 / Double(OnboardingMetrics.tickCount)
        let halfSpan = Double(OnboardingMetrics.turnIndicatorTickSpan) / 2
        let falloff = max(0, 1 - (delta / degreesPerTick) / halfSpan)
        return turn.progress * falloff
    }

    private func triggerPulse() {
        Task {
            pulseActive = true
            try? await Task.sleep(for: .milliseconds(220))
            pulseActive = false
        }
    }
}
