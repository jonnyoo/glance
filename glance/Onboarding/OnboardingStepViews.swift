//
//  OnboardingStepViews.swift
//  glance
//
//  The screens of the notch-hosted onboarding flow (Figma frames 1, 2,
//  3, 4-6 combined, 7, 8, plus the naming step added for multi-identity
//  enrollment, which has no Figma frame). Each fills whatever panel size
//  OnboardingController reports for its step — sizing itself is the notch
//  window's job (see NotchOverlayView), not these views'.
//

import SwiftUI
import AppKit

// MARK: - 1. Intro

struct IntroStepView: View {
    let controller: OnboardingController

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Glance")
                    .font(GlanceTheme.Font.title)
                    .foregroundStyle(GlanceTheme.textPrimary)
                Text("FaceID for Mac")
                    .font(GlanceTheme.Font.button)
                    .foregroundStyle(GlanceTheme.textSecondary)

                Spacer(minLength: 12)

                PillButton(title: "Next") {
                    controller.advance()
                }
            }
            .padding(.leading, 4)
            Spacer(minLength: 4)
            GlanceLogoView()
                .frame(width: 106, height: 106)
                .padding(.top, 4)
        }
        .onboardingContentPadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GlanceTheme.panel)
        .onAppear {
            // Full-screen, like the enrollment step's guidance sweep — not
            // confined to this small notch panel. See
            // `EnrollmentSweepWindowController.presentOnce(direction:)`.
            controller.playIntroSweepIfNeeded()
        }
    }
}

private struct GlanceLogoView: View {
    var body: some View {
        // The video already bakes in its own white rounded-card background
        // (same solid-background convention as the scan animations), so no
        // extra chrome is added here.
        LoopingVideoView(resourceName: "logoanimation")
    }
}

// MARK: - 2. Permissions

struct PermissionsStepView: View {
    let controller: OnboardingController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Permissions")
                .font(GlanceTheme.Font.title)
                .foregroundStyle(GlanceTheme.textPrimary)
                .padding(.leading, 4)

            // Spacer(minLength: 0)

            PermissionRow(
                title: "Accessibility",
                detail: "Allow Glance to unlock your Mac",
                granted: controller.accessibilityGranted
            ) { controller.grantAccessibility() }

            PermissionRow(
                title: "Camera",
                detail: "Allow Glance to recognize your face",
                granted: controller.cameraPermission == .granted
            ) { controller.grantCamera() }

            // Spacer(minLength: 0)

            HStack(spacing: 10) {
                PillButton(title: "Back", style: .secondary) {
                    controller.back()
                }
                PillButton(title: "Next", isEnabled: controller.bothPermissionsGranted) {
                    controller.advance()
                }
            }
        }
        .onboardingContentPadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GlanceTheme.panel)
    }
}

// MARK: - 3. Pre set-up

struct PreSetupStepView: View {
    let controller: OnboardingController

    var body: some View {
        VStack(spacing: 2) {
            HStack(alignment: .top, spacing: 2) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Set up Face\nRecognition")
                        .font(GlanceTheme.Font.title)
                        .foregroundStyle(GlanceTheme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Follow the directions\nshown on the screen")
                        .font(GlanceTheme.Font.button)
                        .foregroundStyle(GlanceTheme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 10)
                .padding(.leading, 4)
                Spacer(minLength: 0)
                UnlockGlyphView()
                    .frame(width: 120, height: 120)
            }
            Spacer(minLength: 4)

            HStack(spacing: 10) {
                PillButton(title: "Back", style: .secondary) {
                    controller.back()
                }
                PillButton(title: "Next") {
                    controller.advance()
                }
            }
        }
        .onboardingContentPadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GlanceTheme.panel)
    }
}

private struct UnlockGlyphView: View {
    var body: some View {
        LoopingVideoView(resourceName: "idleanimation")
    }
}

// MARK: - 4-6. Guided enrollment (camera + tick ring + camera-complete)

struct EnrollStepView: View {
    let controller: OnboardingController
    @Environment(\.notchPanelStyle) private var style

    var body: some View {
        VStack(spacing: 0) {
            cameraCluster
                .padding(.top, cameraTopPadding)
            Spacer(minLength: 8)
            instructionLabel
                .padding(.horizontal, OnboardingMetrics.enrollInstructionHorizontalPadding)
                .padding(.bottom, OnboardingMetrics.enrollInstructionBottomPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topTrailing) {
            if showsCloseButton {
                EnrollmentCloseButton {
                    controller.back()
                }
                .padding(OnboardingMetrics.enrollCloseButtonEdgePadding)
            }
        }
        .background(GlanceTheme.panel)
    }

    private var showsCloseButton: Bool {
        !controller.enrollmentComplete && !controller.showCheckmark
    }

    private var cameraTopPadding: CGFloat {
        style == .pill
            ? OnboardingMetrics.enrollCameraTopPaddingPill
            : OnboardingMetrics.enrollCameraTopPaddingNotch
    }

    private var cameraCluster: some View {
        ZStack {
            EnrollmentRingView(controller: controller)

            CameraPreviewView(session: controller.camera.session, faces: [])
                .frame(
                    width: OnboardingMetrics.cameraCircleDiameter,
                    height: OnboardingMetrics.cameraCircleDiameter
                )
                .clipShape(Circle())
                .opacity(controller.cameraPreviewVisible ? 1 : 0)
                .animation(
                    .easeInOut(duration: OnboardingMetrics.previewFadeOut),
                    value: controller.cameraPreviewVisible
                )
                .overlay {
                    if controller.isTooFar && controller.cameraPreviewVisible && !controller.showCheckmark {
                        EnrollmentTooFarChevron()
                            .transition(.opacity)
                    }
                }
                .animation(.easeInOut(duration: 0.2), value: controller.isTooFar)

            if controller.showCheckmark {
                AnimatedCheckmark(color: GlanceTheme.accent, lineWidth: 8)
                    .frame(width: 70, height: 59)
                    .transition(.opacity)
                    .padding(.top, 4)
            }
        }
        .frame(
            width: OnboardingMetrics.enrollCameraClusterDiameter,
            height: OnboardingMetrics.enrollCameraClusterDiameter
        )
    }

    private var instructionLabel: some View {
        Text(controller.enrollmentInstruction)
            .font(GlanceTheme.Font.instruction)
            .foregroundStyle(.white)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.8)
            .id(controller.enrollmentInstruction)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: controller.enrollmentInstruction)
            .opacity(controller.guideVisible ? 1 : 0)
            .animation(
                .easeInOut(
                    duration: controller.guideVisible
                        ? OnboardingMetrics.enrollInstructionFadeIn
                        : OnboardingMetrics.enrollInstructionFadeOut
                ),
                value: controller.guideVisible
            )
    }
}

private struct EnrollmentCloseButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(isHovering ? 1 : 0.8))
                .frame(
                    width: OnboardingMetrics.enrollCloseButtonSize,
                    height: OnboardingMetrics.enrollCloseButtonSize
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Close")
    }
}

private struct EnrollmentTooFarChevron: View {
    @State private var isAnimating = false

    var body: some View {
        Image(systemName: "chevron.up")
            .font(.system(size: OnboardingMetrics.enrollTooFarChevronSize, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.45), radius: 6, y: 1)
            .symbolEffect(.bounce.up.byLayer, options: .repeating, value: isAnimating)
            .onAppear { isAnimating = true }
            .onDisappear { isAnimating = false }
            .accessibilityHidden(true)
    }
}

// MARK: - 7. Name

/// Asks who was just captured. Reached from every flow that captures poses
/// — first-run setup, "add another face", and a recapture (where the field
/// arrives pre-filled with the existing name, so this doubles as rename).
struct NameStepView: View {
    @Bindable var controller: OnboardingController

    private var trimmedName: String {
        controller.pendingName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Name this face")
                .font(GlanceTheme.Font.title)
                .foregroundStyle(GlanceTheme.textPrimary)
                .padding(.leading, 4)

            Text("Used to tell enrolled faces apart when more than one person is set up on this Mac.")
                .font(GlanceTheme.Font.passwordCaption)
                .foregroundStyle(GlanceTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)

            Spacer(minLength: 2)

            PillTextField(placeholder: "Enter a name...", text: $controller.pendingName, autofocus: true) {
                controller.confirmName()
            }

            if let error = controller.nameError {
                Text(error)
                    .font(GlanceTheme.Font.rowDetail)
                    .foregroundStyle(GlanceTheme.statusDenied)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 10) {
                PillButton(title: "Back", style: .secondary) {
                    controller.back()
                }
                PillButton(title: controller.nameStepPrimaryTitle, isEnabled: !trimmedName.isEmpty, isDefault: true) {
                    controller.confirmName()
                }
            }
        }
        .onboardingContentPadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GlanceTheme.panel)
    }
}

// MARK: - 8. Password

struct PasswordStepView: View {
    let controller: OnboardingController

    @State private var password = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Enter your password")
                .font(GlanceTheme.Font.title)
                .foregroundStyle(GlanceTheme.textPrimary)
                .padding(.leading, 4)

            Text("Your password is required to unlock your Mac. It is encrypted and securely stored on your device. Glance works entirely offline, so your password never leaves your Mac.")
                .font(GlanceTheme.Font.passwordCaption)
                .foregroundStyle(GlanceTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 4)

            Spacer(minLength: 2)

            PillSecureField(placeholder: "Enter password...", text: $password, autofocus: true) {
                guard !password.isEmpty, !controller.isSavingPassword else { return }
                Task { _ = await controller.finish(password: password) }
            }

            if let error = controller.passwordError {
                Text(error)
                    .font(GlanceTheme.Font.rowDetail)
                    .foregroundStyle(GlanceTheme.statusDenied)
            }

            // Spacer(minLength: 0)

            HStack(spacing: 10) {
                PillButton(title: "Back", style: .secondary) {
                    controller.back()
                }
                PillButton(
                    title: controller.isSavingPassword ? "Saving…" : "Confirm",
                    isEnabled: !password.isEmpty && !controller.isSavingPassword,
                    isDefault: true
                ) {
                    Task { _ = await controller.finish(password: password) }
                }
            }
        }
        .onboardingContentPadding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GlanceTheme.panel)
    }
}

// MARK: - 9. Complete

struct CompleteStepView: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("You're all set")
                .font(GlanceTheme.Font.title)
                .foregroundStyle(GlanceTheme.textPrimary)
            Spacer(minLength: 4)
            AnimatedCheckmark(color: .white, lineWidth: 5)
                .frame(width: 20, height: 15)
        }
        .onboardingContentHorizontalPadding()
        .padding(.top, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(GlanceTheme.panel)
    }
}
