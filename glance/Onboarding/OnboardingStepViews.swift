//
//  OnboardingStepViews.swift
//  glance
//
//  The six screens of the notch-hosted onboarding flow (Figma frames 1, 2,
//  3, 4-6 combined, 7, 8). Each fills whatever panel size
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
            Spacer(minLength: 4)
            GlanceLogoView()
                .frame(width: 106, height: 106)
        }
        .padding(.horizontal, OnboardingMetrics.contentHorizontalPadding)
        .padding(.top, OnboardingMetrics.titleTopInset)
        .padding(.bottom, OnboardingMetrics.contentBottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GlanceTheme.panel)
    }
}

private struct GlanceLogoView: View {
    private static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "glance-logo", withExtension: "svg") else { return nil }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        RoundedRectangle(cornerRadius: 21)
            .fill(Color.white)
            .overlay {
                if let image = Self.image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .padding(16)
                }
            }
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
        .padding(.horizontal, OnboardingMetrics.contentHorizontalPadding)
        .padding(.top, OnboardingMetrics.titleTopInset)
        .padding(.bottom, OnboardingMetrics.contentBottomInset)
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
                Spacer(minLength: 0)
                UnlockGlyphView()
                    .frame(width: 126, height: 126)
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
        .padding(.horizontal, OnboardingMetrics.contentHorizontalPadding)
        .padding(.top, OnboardingMetrics.titleTopInset)
        .padding(.bottom, OnboardingMetrics.contentBottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GlanceTheme.panel)
    }
}

private struct UnlockGlyphView: View {
    /// Reuses the same artwork the pre-existing scan overlay shows at rest
    /// — it lives in Resources/, not an asset catalog, so it's loaded by
    /// URL rather than `NSImage(named:)` (see ScanAnimationView).
    private static let image: NSImage? = {
        guard let url = Bundle.main.url(forResource: "unlockstatic", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        if let image = Self.image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        }
    }
}

// MARK: - 4-6. Guided enrollment (camera + tick ring + camera-complete)

struct EnrollStepView: View {
    let controller: OnboardingController

    var body: some View {
        ZStack {
            EnrollmentRingView(controller: controller)

            CameraPreviewView(session: controller.camera.session, faces: [])
                .frame(width: OnboardingMetrics.cameraCircleDiameter, height: OnboardingMetrics.cameraCircleDiameter)
                .clipShape(Circle())
                .opacity(controller.cameraPreviewVisible ? 1 : 0)
                .animation(.easeInOut(duration: OnboardingMetrics.previewFadeOut), value: controller.cameraPreviewVisible)

            if controller.showCheckmark {
                AnimatedCheckmark(color: GlanceTheme.accent, lineWidth: 8)
                    .frame(width: 64, height: 47)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(GlanceTheme.panel)
    }
}

// MARK: - 7. Password

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

            PillSecureField(placeholder: "Enter password...", text: $password)

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
                    isEnabled: !password.isEmpty && !controller.isSavingPassword
                ) {
                    Task { _ = await controller.finish(password: password) }
                }
            }
        }
        .padding(.horizontal, OnboardingMetrics.contentHorizontalPadding)
        .padding(.top, OnboardingMetrics.titleTopInset)
        .padding(.bottom, OnboardingMetrics.contentBottomInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(GlanceTheme.panel)
    }
}

// MARK: - 8. Complete

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
        .padding(.horizontal, OnboardingMetrics.contentHorizontalPadding)
        .padding(.top, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background(GlanceTheme.panel)
    }
}
