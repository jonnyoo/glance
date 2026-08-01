//
//  EnrollmentGuideOverlay.swift
//  glance
//
//  Full-screen content hosted by EnrollmentGuideWindowController: a dark dim
//  over the whole screen, plus — on the notch's screen only — a centered
//  arrow that rotates to the current pose direction and an instruction
//  line below it. Center has no direction, so the arrow hides for it.
//

import SwiftUI

struct EnrollmentGuideOverlay: View {
    let controller: OnboardingController
    let showsArrow: Bool

    private var isCenterPose: Bool {
        controller.currentPose == .center
    }

    private var instructionText: String {
        controller.isTooFar ? "Bring your face closer" : (controller.currentPose?.instruction ?? "")
    }

    var body: some View {
        ZStack {
            Color.black
                .opacity(controller.guideVisible ? OnboardingMetrics.guideDimOpacity : 0)
                .ignoresSafeArea()

            if showsArrow {
                VStack(spacing: OnboardingMetrics.guideTextSpacing) {
                    Image(systemName: "arrowshape.up.fill")
                        .font(.system(size: OnboardingMetrics.guideArrowSize))
                        .foregroundStyle(.white)
                        .opacity(isCenterPose ? 0 : 1)
                        .rotationEffect(.degrees(controller.arrowAngle))
                        .animation(.spring(response: 0.5, dampingFraction: 0.85), value: controller.arrowAngle)
                        .animation(.easeInOut(duration: 0.25), value: isCenterPose)

                    Text(instructionText)
                        .font(GlanceTheme.Font.instruction)
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .id(instructionText)
                        .transition(.opacity)
                }
                .animation(.easeInOut(duration: 0.2), value: instructionText)
                .opacity(controller.guideVisible ? 1 : 0)
                .animation(
                    .easeInOut(duration: controller.guideVisible ? OnboardingMetrics.guideFadeIn : OnboardingMetrics.guideFadeOut),
                    value: controller.guideVisible
                )
            }
        }
    }
}
