//
//  OnboardingController.swift
//  glance
//
//  State machine behind the guided onboarding window: permissions, guided
//  multi-pose face enrollment (auto-capture as the user turns their head),
//  and password setup. Reuses the same camera/detection/embedding/storage
//  pieces as the Face Lab debug tab — this is a polished front door onto the
//  same on-device pipeline, not a separate implementation of it.
//
//  Still not milestone G: finishing onboarding stores an encrypted password
//  and a face template, but nothing here triggers an unlock.
//

import Foundation
import Observation
import AVFoundation
import AppKit

enum OnboardingStep {
    case intro
    case permissions
    case cameraInfo
    case enroll
    case password
}

/// A single guided head pose captured during enrollment. Order matters —
/// this is the sequence shown to the user.
enum EnrollmentPose: Int, CaseIterable {
    case center
    case left
    case right

    var instruction: String {
        switch self {
        case .center: return "Look straight at the camera"
        case .left: return "Slowly turn your head to the left"
        case .right: return "Slowly turn your head to the right"
        }
    }

    var arrowSystemImage: String {
        switch self {
        case .center: return "viewfinder"
        case .left: return "arrow.left.circle.fill"
        case .right: return "arrow.right.circle.fill"
        }
    }
}

enum CameraPermissionState {
    case notDetermined
    case granted
    case denied
}

@Observable
@MainActor
final class OnboardingController {
    let camera = CameraManager()
    private let embedder: FaceEmbedder = VisionFeaturePrintEmbedder()
    private let store = FaceEnrollmentStore.shared

    private(set) var step: OnboardingStep = .intro

    // MARK: - Permissions

    private(set) var accessibilityGranted = false
    private(set) var cameraPermission: CameraPermissionState = .notDetermined
    var bothPermissionsGranted: Bool { accessibilityGranted && cameraPermission == .granted }

    private var permissionsPollTask: Task<Void, Never>?

    // MARK: - Enrollment

    /// Samples needed per pose before advancing. 3 poses x 3 samples = 9
    /// total, roughly ~10-20s of natural head movement.
    private let samplesPerPose = 3
    /// Consecutive matching frames required before a capture fires — a
    /// simple debounce so a single lucky frame near a pose boundary doesn't
    /// trigger a capture, and consecutive captures are naturally spaced out.
    private let requiredMatchStreak = 5
    /// Vision's capture-quality score has no fixed universal cutoff; this is
    /// a permissive floor so we don't block enrollment on a nil/low score
    /// from a fast-moving frame — better to accept a mediocre sample than to
    /// stall the whole flow.
    private let qualityFloor: Float = 0.2

    private(set) var currentPoseIndex = 0
    private(set) var capturedForCurrentPose = 0
    private(set) var faceDetected = false
    private(set) var currentYaw: Float?
    private(set) var enrollmentComplete = false

    private var collectedSamples: [[Float]] = []
    private var matchStreak = 0
    private var isProcessingFrame = false

    var currentPose: EnrollmentPose? {
        EnrollmentPose(rawValue: currentPoseIndex)
    }

    var overallEnrollmentProgress: Double {
        let total = Double(EnrollmentPose.allCases.count * samplesPerPose)
        let done = Double(currentPoseIndex * samplesPerPose + capturedForCurrentPose)
        return min(done / total, 1.0)
    }

    // MARK: - Password

    private(set) var passwordError: String?
    private(set) var isSavingPassword = false

    init() {
        observeFrames()
    }

    // MARK: - Navigation

    func advance() {
        switch step {
        case .intro: step = .permissions; startPermissionsPolling()
        case .permissions: stopPermissionsPolling(); step = .cameraInfo
        case .cameraInfo: step = .enroll
        case .enroll: break // advances automatically on completion
        case .password: break // handled by finish(password:)
        }
    }

    func startEnrollment() {
        step = .enroll
        Task { await camera.start() }
    }

    func stopCamera() {
        stopPermissionsPolling()
        camera.stop()
    }

    // MARK: - Permissions

    private func startPermissionsPolling() {
        refreshPermissions()
        permissionsPollTask?.cancel()
        permissionsPollTask = Task { [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                self.refreshPermissions()
            }
        }
    }

    private func stopPermissionsPolling() {
        permissionsPollTask?.cancel()
        permissionsPollTask = nil
    }

    private func refreshPermissions() {
        accessibilityGranted = KeystrokeInjector.isAccessibilityTrusted()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: cameraPermission = .granted
        case .notDetermined: cameraPermission = .notDetermined
        default: cameraPermission = .denied
        }
    }

    func grantAccessibility() {
        KeystrokeInjector.promptForAccessibility()
    }

    func grantCamera() {
        Task {
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                refreshPermissions()
            } else {
                openSystemSettings(pane: "Privacy_Camera")
            }
        }
    }

    private func openSystemSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Guided enrollment

    private func observeFrames() {
        withObservationTracking {
            _ = camera.currentFrame
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeFrames()
                await self?.processEnrollFrame()
            }
        }
    }

    private func processEnrollFrame() async {
        guard step == .enroll, !enrollmentComplete, !isProcessingFrame,
              let frame = camera.currentFrame, let pose = currentPose else { return }
        isProcessingFrame = true
        defer { isProcessingFrame = false }

        let faces = (try? await Task.detached(priority: .userInitiated) {
            try FaceDetector.detectFaces(in: frame)
        }.value) ?? []

        guard let face = faces.first, let yaw = face.yaw else {
            faceDetected = false
            currentYaw = nil
            matchStreak = 0
            return
        }
        faceDetected = true
        currentYaw = yaw

        let qualityOK = face.quality.map { $0 >= qualityFloor } ?? true
        guard qualityOK, yawMatches(yaw, pose: pose) else {
            matchStreak = 0
            return
        }

        matchStreak += 1
        guard matchStreak >= requiredMatchStreak else { return }
        matchStreak = 0

        guard let crop = FaceDetector.crop(face, from: frame) else { return }
        let embedder = self.embedder
        let embeddingResult = try? await Task.detached(priority: .userInitiated) {
            try embedder.embedding(for: crop)
        }.value
        guard let embedding = embeddingResult else { return }

        collectedSamples.append(embedding)
        capturedForCurrentPose += 1

        if capturedForCurrentPose >= samplesPerPose {
            currentPoseIndex += 1
            capturedForCurrentPose = 0
            if currentPoseIndex >= EnrollmentPose.allCases.count {
                await finishEnrollment()
            }
        }
    }

    /// Vision's yaw sign convention for "turned toward the user's left" vs.
    /// "right" wasn't verified against the mirrored front-camera preview
    /// before shipping this — if the on-screen arrow direction doesn't match
    /// the way the user actually has to turn, swap the comparisons below.
    private func yawMatches(_ yaw: Float, pose: EnrollmentPose) -> Bool {
        switch pose {
        case .center: return abs(yaw) < 0.2
        case .left: return yaw > 0.3 && yaw < 1.2
        case .right: return yaw < -0.3 && yaw > -1.2
        }
    }

    private func finishEnrollment() async {
        let embedderName = embedder.name
        for sample in collectedSamples {
            store.addSample(name: Self.ownerName, embedding: sample, embedderName: embedderName)
        }
        enrollmentComplete = true
        camera.stop()
        try? await Task.sleep(for: .seconds(1.5))
        step = .password
    }

    private static let ownerName: String = {
        let name = NSFullUserName()
        return name.isEmpty ? "Owner" : name
    }()

    // MARK: - Password

    func finish(password: String) async -> Bool {
        let trimmed = password
        guard !trimmed.isEmpty else {
            passwordError = "Enter a password."
            return false
        }
        isSavingPassword = true
        defer { isSavingPassword = false }

        do {
            try await Task.detached(priority: .userInitiated) {
                try SecureCredentialManager.unlockSession(reason: "Set up Glance")
            }.value
            try await Task.detached(priority: .userInitiated) {
                guard var bytes = trimmed.data(using: .utf8) else {
                    throw SecureCredentialError.emptyPassword
                }
                defer { bytes.resetBytes(in: 0..<bytes.count) }
                try SecureCredentialManager.savePassword(bytes)
            }.value
            passwordError = nil
            return true
        } catch {
            passwordError = error.localizedDescription
            return false
        }
    }
}
