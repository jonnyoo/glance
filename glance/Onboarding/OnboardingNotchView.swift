//
//  OnboardingNotchView.swift
//  glance
//
//  Root of the onboarding flow, hosted inside the notch panel by
//  NotchOverlayView. Routes `controller.step` to its screen and applies the
//  scroll-with-blur transition between them.
//
//  On Next, both the outgoing and incoming screens travel upward — the
//  current content scrolls up and away while the next one scrolls up into
//  place from below. Back is the mirror: everything travels downward, the
//  previous screen arriving from above.
//

import SwiftUI

struct OnboardingNotchView: View {
    let controller: OnboardingController

    var body: some View {
        ZStack {
            switch controller.step {
            case .intro:
                IntroStepView(controller: controller)
            case .permissions:
                PermissionsStepView(controller: controller)
            case .preSetup:
                PreSetupStepView(controller: controller)
            case .enroll:
                EnrollStepView(controller: controller)
            case .name:
                NameStepView(controller: controller)
            case .password:
                PasswordStepView(controller: controller)
            case .complete:
                CompleteStepView()
            }
        }
        .id(controller.step)
        .frame(width: controller.panelSize.width, height: controller.panelSize.height)
        .transition(stepTransition)
    }

    private var stepTransition: AnyTransition {
        let travel = controller.panelSize.height
        let insertionOffset: CGFloat = controller.navDirection == .forward ? travel : -travel
        let removalOffset: CGFloat = controller.navDirection == .forward ? -travel : travel
        return .asymmetric(
            insertion: .modifier(
                active: OffsetBlurOpacity(offset: insertionOffset, blur: 12, opacity: 0),
                identity: OffsetBlurOpacity(offset: 0, blur: 0, opacity: 1)
            ),
            removal: .modifier(
                active: OffsetBlurOpacity(offset: removalOffset, blur: 12, opacity: 0),
                identity: OffsetBlurOpacity(offset: 0, blur: 0, opacity: 1)
            )
        )
    }
}

/// Backing modifier for the scroll+blur transition — offsets vertically,
/// blurs, and fades all at once so entering/exiting content reads as
/// scrolling past with a dissolve rather than a hard cut.
private struct OffsetBlurOpacity: ViewModifier {
    let offset: CGFloat
    let blur: CGFloat
    let opacity: Double

    func body(content: Content) -> some View {
        content
            .offset(y: offset)
            .blur(radius: blur)
            .opacity(opacity)
    }
}
