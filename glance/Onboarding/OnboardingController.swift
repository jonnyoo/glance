//
//  OnboardingController.swift
//  glance
//
//  State machine behind the notch-hosted guided onboarding flow:
//  permissions, guided nine-pose face enrollment (auto-capture as the user
//  turns/tilts their head through 8 compass directions plus center), and
//  password setup. Reuses the same camera/detection/embedding/storage
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
import SwiftUI

enum OnboardingStep: CaseIterable {
    case intro
    case permissions
    case preSetup
    case enroll
    case password
    case complete

    var previous: OnboardingStep? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index > 0 else { return nil }
        return all[index - 1]
    }

    /// Whether this step shows the Figma "Back"/primary button pair. Enroll
    /// is fully guided (no buttons); complete and intro have only one side.
    var showsBackButton: Bool {
        switch self {
        case .permissions, .preSetup, .password: return true
        case .intro, .enroll, .complete: return false
        }
    }
}

/// A single guided head pose captured during enrollment — center plus the
/// 8 compass directions, in the exact order presented to the user.
enum EnrollmentPose: Int, CaseIterable {
    case center, left, topLeft, top, topRight, right, bottomRight, bottom, bottomLeft

    enum YawBand { case left, none, right }
    enum PitchBand { case up, none, down }

    var yawBand: YawBand {
        switch self {
        case .left, .topLeft, .bottomLeft: return .left
        case .right, .topRight, .bottomRight: return .right
        case .center, .top, .bottom: return .none
        }
    }

    var pitchBand: PitchBand {
        switch self {
        case .top, .topLeft, .topRight: return .up
        case .bottom, .bottomLeft, .bottomRight: return .down
        case .center, .left, .right: return .none
        }
    }

    /// Compass angle (0 = up, clockwise) this pose's ring sector is centered
    /// on. `nil` for center, which pulses the whole ring instead of
    /// claiming a sector.
    var compassAngle: Double? {
        switch self {
        case .center: return nil
        case .left: return 270
        case .topLeft: return 315
        case .top: return 0
        case .topRight: return 45
        case .right: return 90
        case .bottomRight: return 135
        case .bottom: return 180
        case .bottomLeft: return 225
        }
    }

    var instruction: String {
        switch self {
        case .center: return "Look straight at the camera"
        case .left: return "Tilt your head slightly left"
        case .topLeft: return "Tilt your head to the top left"
        case .top: return "Tilt your head slightly up"
        case .topRight: return "Tilt your head to the top right"
        case .right: return "Tilt your head slightly right"
        case .bottomRight: return "Tilt your head to the bottom right"
        case .bottom: return "Tilt your head slightly down"
        case .bottomLeft: return "Tilt your head to the bottom left"
        }
    }

    /// Persisted alongside each sample so a saved identity records which
    /// pose each embedding came from.
    var name: String {
        switch self {
        case .center: return "center"
        case .left: return "left"
        case .topLeft: return "top_left"
        case .top: return "top"
        case .topRight: return "top_right"
        case .right: return "right"
        case .bottomRight: return "bottom_right"
        case .bottom: return "bottom"
        case .bottomLeft: return "bottom_left"
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
    let pipeline = FaceRecognitionPipeline()
    private let store = FaceEnrollmentStore.shared
    private let guideWindowController = EnrollmentGuideWindowController()

    private(set) var step: OnboardingStep = .intro

    enum NavDirection { case forward, backward }
    /// Which way the step just changed — read by OnboardingNotchView to
    /// pick the scroll direction for the blur transition.
    private(set) var navDirection: NavDirection = .forward

    /// Entry point used by Face Lab's "Start Onboarding" button. Onboarding
    /// has no window of its own — it's presented entirely inside the notch.
    static func startFlow() {
        let controller = OnboardingController()
        NotchOverlayController.shared.presentOnboarding(controller)
    }

    // MARK: - Panel sizing (read by NotchOverlayView)

    var panelSize: CGSize { OnboardingMetrics.panelSize(for: step) }
    var panelBottomRadius: CGFloat { OnboardingMetrics.panelBottomRadius(for: step) }

    // MARK: - Permissions

    private(set) var accessibilityGranted = false
    private(set) var cameraPermission: CameraPermissionState = .notDetermined
    var bothPermissionsGranted: Bool { accessibilityGranted && cameraPermission == .granted }

    private var permissionsPollTask: Task<Void, Never>?

    // MARK: - Enrollment

    /// Samples needed per pose before advancing. 9 poses x 2 samples = 18
    /// total — enough for a stable template across 9 poses without making
    /// the user hold each one too long.
    private let samplesPerPose = 2
    /// Consecutive matching frames required before a capture fires — a
    /// simple debounce so a single lucky frame near a pose boundary doesn't
    /// trigger a capture, and consecutive captures are naturally spaced out.
    private let requiredMatchStreak = 3
    /// Vision's capture-quality score has no fixed universal cutoff; this is
    /// a permissive floor so we don't block enrollment on a nil/low score
    /// from a fast-moving frame — better to accept a mediocre sample than to
    /// stall the whole flow.
    private let qualityFloor: Float = 0.2

    // Pose-matching bands, in radians. Yaw's sign (left turn -> positive)
    // matches the mirrored front-camera preview as expected. Pitch's sign
    // is the opposite of the initial guess — see `pitchMatches` below.
    private let yawInnerThreshold: Float = 0.25
    private let yawCenterTolerance: Float = 0.18
    private let yawOuterCap: Float = 1.2
    private let pitchInnerThreshold: Float = 0.20
    private let pitchCenterTolerance: Float = 0.15
    private let pitchOuterCap: Float = 0.9
    /// If a pose takes longer than this to capture, matching bands widen by
    /// `stallWidenFactor` so an unusual camera angle or seating position
    /// can't permanently strand the user on one step.
    private let stallTimeout: Duration = .seconds(12)
    private let stallWidenFactor: Float = 1.25

    private(set) var currentPoseIndex = 0
    private(set) var capturedForCurrentPose = 0
    private(set) var faceDetected = false
    private(set) var currentYaw: Float?
    private(set) var currentPitch: Float?
    private(set) var enrollmentComplete = false

    /// Sectors already captured — read by EnrollmentRingView to decide which
    /// ticks are lit.
    private(set) var capturedPoses: Set<EnrollmentPose> = []
    /// Bumped every time `.center` is captured; EnrollmentRingView observes
    /// this to trigger the whole-ring pulse (center has no sector of its
    /// own to light).
    private(set) var centerPulseTick = 0

    /// Whether the full-screen dim + arrow + instruction overlay should be
    /// visible right now — false once enrollment completes, ahead of the
    /// checkmark sequence.
    private(set) var guideVisible = false
    /// Whether the camera preview should be visible — faded out as part of
    /// the camera-complete sequence.
    private(set) var cameraPreviewVisible = true
    /// Whether the completion checkmark should be drawing/shown.
    private(set) var showCheckmark = false

    private struct CollectedSample {
        let embedding: [Float]
        let pose: EnrollmentPose
    }
    /// Held in memory (not persisted) until the password step succeeds —
    /// saving requires an unlocked session (see SecureFaceStore), and
    /// nothing unlocks the session until `finish(password:)` calls
    /// `SecureCredentialManager.unlockSession`, which happens after
    /// enrollment in this flow's step order.
    private var collectedSamples: [CollectedSample] = []
    private var matchStreak = 0
    private var isProcessingFrame = false
    private var poseStartedAt: ContinuousClock.Instant = .now

    var currentPose: EnrollmentPose? {
        EnrollmentPose(rawValue: currentPoseIndex)
    }

    /// Running clockwise rotation for the full-screen arrow. A direct
    /// formula (not an incremented running total) so it's always derived
    /// from `currentPoseIndex` alone, yet still never "wraps backward" at
    /// the 315->0 compass boundary — SwiftUI animates the raw numeric
    /// value, so 270, 315, 360, 405... reads as continuous clockwise
    /// motion instead of snapping back through 0.
    var arrowAngle: Double {
        let leftBase = EnrollmentPose.left.compassAngle ?? 270
        guard currentPoseIndex >= 1 else { return leftBase }
        return leftBase + Double(currentPoseIndex - 1) * 45
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
        navDirection = .forward
        let leavingStep = step
        withAnimation(OnboardingMetrics.stepAnimation) {
            switch step {
            case .intro: step = .permissions
            case .permissions: step = .preSetup
            case .preSetup: step = .enroll
            case .enroll: break // advances automatically on completion
            case .password: break // handled by finish(password:)
            case .complete: break
            }
        }
        if leavingStep == .permissions { stopPermissionsPolling() }
        switch step {
        case .permissions: startPermissionsPolling()
        case .enroll: beginEnrollment()
        default: break
        }
    }

    /// Steps backward. `.enroll` is fully guided (no Back button reaches
    /// it), so backing out of `.password` skips over it straight to
    /// `.preSetup` — enrollment can't be resumed halfway, so this also
    /// resets all collected progress; the user re-does the guided capture
    /// on their way forward again.
    func back() {
        navDirection = .backward
        if step == .password {
            resetEnrollmentState()
            withAnimation(OnboardingMetrics.stepAnimation) { step = .preSetup }
            return
        }
        guard let previous = step.previous else { return }
        withAnimation(OnboardingMetrics.stepAnimation) { step = previous }
        if step == .permissions {
            startPermissionsPolling()
        }
    }

    private func resetEnrollmentState() {
        collectedSamples = []
        currentPoseIndex = 0
        capturedForCurrentPose = 0
        capturedPoses = []
        matchStreak = 0
        enrollmentComplete = false
        guideVisible = false
        cameraPreviewVisible = true
        showCheckmark = false
        passwordError = nil
    }

    private func beginEnrollment() {
        guideVisible = true
        cameraPreviewVisible = true
        showCheckmark = false
        poseStartedAt = .now
        Task { await camera.start() }
        guideWindowController.present(for: self)
    }

    /// Tears down everything onboarding spun up: camera, permissions
    /// polling, and the full-screen guide windows. Idempotent.
    func teardown() {
        stopPermissionsPolling()
        camera.stop()
        guideWindowController.dismiss()
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

        let pipeline = self.pipeline
        let result = try? await Task.detached(priority: .userInitiated) {
            try pipeline.recognize(in: frame)
        }.value

        guard let result, let yaw = result.face.yaw, let pitch = result.face.pitch else {
            faceDetected = false
            currentYaw = nil
            currentPitch = nil
            matchStreak = 0
            return
        }
        faceDetected = true
        currentYaw = yaw
        currentPitch = pitch

        let qualityOK = result.quality.map { $0 >= qualityFloor } ?? true
        // Only a 5-point alignment produces a reliably canonical input —
        // a 2-point or padded-crop fallback (more likely exactly during a
        // turned/tilted pose, where landmarks are harder to find) isn't
        // accepted toward enrollment.
        let alignmentOK = result.alignmentTier == .fivePoint
        let widened = ContinuousClock.now - poseStartedAt > stallTimeout
        guard qualityOK, alignmentOK, poseMatches(yaw: yaw, pitch: pitch, pose: pose, widened: widened) else {
            matchStreak = 0
            return
        }

        matchStreak += 1
        guard matchStreak >= requiredMatchStreak else { return }
        matchStreak = 0

        collectedSamples.append(CollectedSample(embedding: result.embedding, pose: pose))
        capturedForCurrentPose += 1

        if capturedForCurrentPose >= samplesPerPose {
            if pose == .center {
                centerPulseTick += 1
            } else {
                capturedPoses.insert(pose)
            }
            currentPoseIndex += 1
            capturedForCurrentPose = 0
            poseStartedAt = .now
            if currentPoseIndex >= EnrollmentPose.allCases.count {
                await finishEnrollment()
            }
        }
    }

    private func poseMatches(yaw: Float, pitch: Float, pose: EnrollmentPose, widened: Bool) -> Bool {
        let factor: Float = widened ? stallWidenFactor : 1.0
        return yawMatches(yaw, band: pose.yawBand, factor: factor)
            && pitchMatches(pitch, band: pose.pitchBand, factor: factor)
    }

    private func yawMatches(_ yaw: Float, band: EnrollmentPose.YawBand, factor: Float) -> Bool {
        switch band {
        case .none: return abs(yaw) < yawCenterTolerance * factor
        case .left: return yaw > yawInnerThreshold / factor && yaw < yawOuterCap
        case .right: return yaw < -yawInnerThreshold / factor && yaw > -yawOuterCap
        }
    }

    /// Confirmed empirically against Face Lab's live yaw/pitch readout:
    /// Vision reports a *negative* pitch for "looking up" and positive for
    /// "looking down" — the opposite of the initial guess (see the class
    /// doc comment above the threshold constants). Bands below are written
    /// against that confirmed convention.
    private func pitchMatches(_ pitch: Float, band: EnrollmentPose.PitchBand, factor: Float) -> Bool {
        switch band {
        case .none: return abs(pitch) < pitchCenterTolerance * factor
        case .up: return pitch < -pitchInnerThreshold / factor && pitch > -pitchOuterCap
        case .down: return pitch > pitchInnerThreshold / factor && pitch < pitchOuterCap
        }
    }

    /// Runs the camera-complete sequence: guide overlay fades, camera
    /// preview fades, the checkmark draws on, then auto-advances to the
    /// password step. Samples stay in memory here — persisting requires an
    /// unlocked session, which doesn't exist until `finish(password:)`
    /// calls `SecureCredentialManager.unlockSession` below.
    private func finishEnrollment() async {
        enrollmentComplete = true

        guideVisible = false
        try? await Task.sleep(for: .seconds(OnboardingMetrics.guideOverlayFadeOut))
        guideWindowController.dismiss()

        cameraPreviewVisible = false
        try? await Task.sleep(for: .seconds(OnboardingMetrics.previewFadeOut))

        try? await Task.sleep(for: .seconds(OnboardingMetrics.checkmarkDelay))
        showCheckmark = true

        let elapsed = OnboardingMetrics.guideOverlayFadeOut + OnboardingMetrics.previewFadeOut + OnboardingMetrics.checkmarkDelay
        let remaining = max(OnboardingMetrics.cameraCompleteToPasswordDelay - elapsed, 0)
        try? await Task.sleep(for: .seconds(remaining))

        camera.stop()
        navDirection = .forward
        withAnimation(OnboardingMetrics.stepAnimation) { step = .password }
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

            // Only now that the session key exists can the face samples
            // collected during enrollment actually be encrypted and saved.
            store.reloadIfUnlocked()
            let embedder = pipeline.embedder
            for sample in collectedSamples {
                _ = try? store.addSample(name: Self.ownerName, embedding: sample.embedding, embedder: embedder, pose: sample.pose.name)
            }

            try await Task.detached(priority: .userInitiated) {
                guard var bytes = trimmed.data(using: .utf8) else {
                    throw SecureCredentialError.emptyPassword
                }
                defer { bytes.resetBytes(in: 0..<bytes.count) }
                try SecureCredentialManager.savePassword(bytes)
            }.value
            passwordError = nil
            navDirection = .forward
            withAnimation(OnboardingMetrics.stepAnimation) { step = .complete }
            scheduleCompletionDismiss()
            return true
        } catch {
            passwordError = error.localizedDescription
            return false
        }
    }

    /// The "You're all set" screen has no controls — it dismisses itself.
    private func scheduleCompletionDismiss() {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(OnboardingMetrics.completeScreenDismissDelay))
            guard let self else { return }
            self.teardown()
            NotchOverlayController.shared.dismissOnboarding()
        }
    }
}
