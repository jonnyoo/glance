//
//  OnboardingSteps.swift
//  glance
//
//  The five screens of the guided onboarding window.
//

import SwiftUI

// MARK: - 1. Intro

struct IntroStepView: View {
    let controller: OnboardingController

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            VStack(spacing: 8) {
                Text("Glance")
                    .font(.system(size: 40, weight: .bold))
                Text("Unlock your Mac with a glance.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            RoundedRectangle(cornerRadius: 16)
                .fill(Color.gray.opacity(0.12))
                .frame(width: 260, height: 260)
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: "video.fill")
                            .font(.system(size: 40))
                            .foregroundStyle(.secondary)
                        Text("Video coming soon")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

            Spacer()

            Button("Next") {
                controller.advance()
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }
}

// MARK: - 2. Permissions

struct PermissionsStepView: View {
    let controller: OnboardingController

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("Permissions")
                    .font(.largeTitle.bold())
                Text("Glance needs a couple of permissions to work.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 40)

            Spacer()

            VStack(spacing: 16) {
                permissionRow(
                    title: "Accessibility",
                    detail: "Lets Glance type your password at the lock screen.",
                    granted: controller.accessibilityGranted
                ) {
                    controller.grantAccessibility()
                }

                permissionRow(
                    title: "Camera",
                    detail: "Lets Glance recognize your face.",
                    granted: controller.cameraPermission == .granted
                ) {
                    controller.grantCamera()
                }
            }

            Spacer()

            ZStack {
                if controller.bothPermissionsGranted {
                    Button("Next") {
                        controller.advance()
                    }
                    .controlSize(.large)
                    .buttonStyle(.borderedProminent)
                    .transition(.opacity)
                }
            }
            .frame(height: 44)
            .animation(.easeInOut, value: controller.bothPermissionsGranted)
        }
        .padding(32)
    }

    private func permissionRow(
        title: String,
        detail: String,
        granted: Bool,
        grant: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(granted ? .green : .red)
                .frame(width: 10, height: 10)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            Button(granted ? "Granted" : "Grant") {
                grant()
            }
            .disabled(granted)
        }
        .padding(12)
        .background(Color.gray.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - 3. Camera info

struct CameraInfoStepView: View {
    let controller: OnboardingController

    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            Image(systemName: "faceid")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            VStack(spacing: 8) {
                Text("Set up face recognition")
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text("Position your face within the camera frame and tilt your head slightly according to the directions shown on screen.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 16)

            Spacer()

            Button("Get Started") {
                controller.startEnrollment()
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }
}

// MARK: - 4. Guided enrollment

struct EnrollStepView: View {
    let controller: OnboardingController

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            ZStack {
                Circle()
                    .stroke(Color.gray.opacity(0.2), lineWidth: 8)
                    .frame(width: 260, height: 260)

                Circle()
                    .trim(from: 0, to: controller.overallEnrollmentProgress)
                    .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .frame(width: 260, height: 260)
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut, value: controller.overallEnrollmentProgress)

                CameraPreviewView(session: controller.camera.session, faces: [])
                    .frame(width: 232, height: 232)
                    .clipShape(Circle())

                if controller.enrollmentComplete {
                    Circle()
                        .fill(.black.opacity(0.55))
                        .frame(width: 232, height: 232)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.6), value: controller.enrollmentComplete)

            Group {
                if controller.enrollmentComplete {
                    Text("All set!")
                        .font(.title2.bold())
                } else if let pose = controller.currentPose {
                    VStack(spacing: 8) {
                        Image(systemName: pose.arrowSystemImage)
                            .font(.system(size: 28))
                            .foregroundStyle(.tint)
                        Text(pose.instruction)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                        if !controller.faceDetected {
                            Text("No face detected — center yourself in the frame")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(height: 80)

            if let error = controller.camera.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }

            Spacer()
        }
        .padding(32)
    }
}

// MARK: - 5. Password

struct PasswordStepView: View {
    let controller: OnboardingController
    let onFinish: () -> Void

    @State private var password = ""

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("Enter your password")
                    .font(.largeTitle.bold())
                Text("Your password is stored encrypted on this Mac and used only to sign you in after Glance recognizes your face. It never leaves your device and is never sent over the internet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
            .padding(.top, 40)

            Spacer()

            SecureField("Mac password", text: $password)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)

            if let error = controller.passwordError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Spacer()

            Button(controller.isSavingPassword ? "Saving…" : "Finish") {
                Task {
                    if await controller.finish(password: password) {
                        onFinish()
                    }
                }
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .disabled(password.isEmpty || controller.isSavingPassword)
        }
        .padding(32)
    }
}
