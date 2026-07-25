//
//  OnboardingView.swift
//  glance
//
//  Root container for the guided onboarding window: fixed size, no window
//  chrome fuss, just the current step.
//

import SwiftUI

struct OnboardingView: View {
    @State private var controller = OnboardingController()
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            switch controller.step {
            case .intro:
                IntroStepView(controller: controller)
            case .permissions:
                PermissionsStepView(controller: controller)
            case .cameraInfo:
                CameraInfoStepView(controller: controller)
            case .enroll:
                EnrollStepView(controller: controller)
            case .password:
                PasswordStepView(controller: controller) {
                    dismissWindow(id: "onboarding")
                }
            }
        }
        .frame(width: 420, height: 560)
        .onDisappear {
            controller.stopCamera()
        }
    }
}

#Preview {
    OnboardingView()
}
