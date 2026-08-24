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
    case name
    case password
    case complete

    var previous: OnboardingStep? {
        let all = Self.allCases
        guard let index = all.firstIndex(of: self), index > 0 else { return nil }
        return all[index - 1]
    }

    /// Whether this step shows the Figma "Back"/primary button pair. Enroll
    /// is fully guided (close control only); complete and intro have only
    /// one side.
    var showsBackButton: Bool {
        switch self {
        case .permissions, .preSetup, .name, .password: return true
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
    private let sweepWindow = EnrollmentSweepWindowController()

    private(set) var step: OnboardingStep = .intro

    /// True when this flow was started by `startEnrollmentOnly()` — shows
    /// only the guided pose-capture step (reusing `.enroll`, no new
    /// `OnboardingStep` case needed) and saves samples directly on
    /// completion instead of continuing on to the password step.
    private let isEnrollmentOnly: Bool

    /// True when started by `startPasswordOnly()` — the mirror image of
    /// `isEnrollmentOnly`: jumps straight to `.password` and treats Back as
    /// "cancel" rather than stepping into a setup flow that isn't running.
    private let isPasswordOnly: Bool

    /// Who this run is enrolling. Recapture is keyed by `id` rather than by
    /// name so the naming step can rename an identity in the same pass —
    /// matching by name would either lose the rename or orphan the old
    /// identity under its old name.
    enum EnrollmentTarget: Equatable {
        case newIdentity
        case replacing(UUID)

        var identityID: UUID? {
            if case .replacing(let id) = self { return id }
            return nil
        }
    }

    private let enrollmentTarget: EnrollmentTarget

    enum NavDirection { case forward, backward }
    /// Which way the step just changed — read by OnboardingNotchView to
    /// pick the scroll direction for the blur transition.
    private(set) var navDirection: NavDirection = .forward

    /// Entry point used by Face Lab's "Start Onboarding" button. Onboarding
    /// has no window of its own — it's presented entirely inside the notch.
    static func startFlow() {
        let controller = OnboardingController()
        controller.pendingName = defaultName
        NotchOverlayController.shared.presentOnboarding(controller)
    }

    /// Entry point used by Settings' "Set up FaceID" / "Redo Face
    /// Enrollment" — presents the guided pose-capture step plus the naming
    /// step (no intro/permissions/password) and saves directly once done.
    ///
    /// The Your Face page is still single-identity (it reads
    /// `identities.first`), so this keeps targeting that first identity:
    /// "redo" replaces it in place, and with nothing enrolled it enrolls
    /// someone new.
    static func startEnrollmentOnly() {
        Task { @MainActor in
            guard await unlockForEnrollment(reason: "Authenticate to re-enroll your face") else { return }
            let store = FaceEnrollmentStore.shared
            store.reloadIfUnlocked()
            let existing = store.identities.first
            present(
                target: existing.map { .replacing($0.id) } ?? .newIdentity,
                prefillName: existing?.name ?? defaultName
            )
        }
    }

    /// Entry point used by Face Lab's "Add Identity" — the same guided
    /// capture, but always enrolling a *new* person alongside whoever is
    /// already enrolled. The name starts empty rather than at `defaultName`:
    /// this is explicitly somebody else.
    static func startAddIdentity() {
        Task { @MainActor in
            guard await unlockForEnrollment(reason: "Authenticate to enroll another face") else { return }
            FaceEnrollmentStore.shared.reloadIfUnlocked()
            present(target: .newIdentity, prefillName: "")
        }
    }

    /// Entry point used by Face Lab's per-identity "Recapture" — replaces
    /// that identity's samples wholesale, keeping its id and enrollment
    /// date, with its current name pre-filled and editable.
    static func startRecapture(of identity: FaceIdentity) {
        Task { @MainActor in
            guard await unlockForEnrollment(reason: "Authenticate to re-enroll this face") else { return }
            FaceEnrollmentStore.shared.reloadIfUnlocked()
            present(target: .replacing(identity.id), prefillName: identity.name)
        }
    }

    /// Enrollment-only flows persist as soon as the naming step is
    /// confirmed, so unlike the full setup flow there's no later password
    /// step to unlock the session — Touch ID has to happen up front, before
    /// the notch ever appears.
    private static func unlockForEnrollment(reason: String) async -> Bool {
        guard !SecureCredentialManager.isSessionUnlocked else { return true }
        do {
            try await Task.detached(priority: .userInitiated) {
                try SecureCredentialManager.unlockSession(reason: reason)
            }.value
            return true
        } catch {
            return false
        }
    }

    private static func present(target: EnrollmentTarget, prefillName: String) {
        let controller = OnboardingController(isEnrollmentOnly: true, enrollmentTarget: target)
        controller.pendingName = prefillName
        NotchOverlayController.shared.presentOnboarding(controller)
    }

    /// Entry point used by Settings' "Change password" — presents only the
    /// password step in the notch, reusing the same field, validation and
    /// save path as first-run setup rather than duplicating them in a
    /// settings-only form.
    ///
    /// No Touch ID prompt here, unlike `startEnrollmentOnly()`: the only
    /// caller is the Password page's unlocked state, which by definition
    /// already has a live session. `finish(password:)` re-asserts that
    /// anyway, so a session that lapsed in between still can't save silently.
    static func startPasswordOnly() {
        Task { @MainActor in
            let controller = OnboardingController(isPasswordOnly: true)
            NotchOverlayController.shared.presentOnboarding(controller)
        }
    }

    // MARK: - Panel sizing (read by NotchOverlayView)

    /// The silhouette the panel is currently wearing — read fresh off the
    /// preferred screen each time rather than cached, same as
    /// `NotchWindowController.currentGeometry`, so it stays correct across a
    /// display change mid-flow.
    private var currentPanelStyle: NotchPanelStyle {
        NotchGeometry.preferredScreen().map(NotchGeometry.forScreen)?.style ?? .notch
    }

    var panelSize: CGSize { OnboardingMetrics.panelSize(for: step, style: currentPanelStyle) }
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
    /// Once yaw/pitch (or center) already matches the current pose, wait
    /// this long before samples start counting so the user has settled
    /// into the turn rather than being captured mid-motion.
    private let poseHoldDuration: Duration = .milliseconds(500)
    /// Vision's capture-quality score has no fixed universal cutoff; this is
    /// a permissive floor so we don't block enrollment on a nil/low score
    /// from a fast-moving frame — better to accept a mediocre sample than to
    /// stall the whole flow.
    private let qualityFloor: Float = 0.2
    /// How long to hold off accepting captures once the camera comes up —
    /// enough for the user to settle into frame and look at the camera
    /// before the center pose starts counting, so the first samples aren't
    /// taken mid-blink or mid-flinch. Detection and the ring's live
    /// yaw/pitch readout still run during this window; only capture is held
    /// back.
    private let initialCaptureDelay: Duration = .seconds(1.5)
    /// Enrollment wants a closer face than unlock's bystander cutoff —
    /// sitting back in a chair is still "prominent" enough to unlock, but
    /// too far for a reliable template. Floor is still the shared
    /// prominence width so a tighter Recognition setting can't be bypassed.
    private var enrollmentMinimumFaceWidth: Float {
        max(FaceRecognitionPipeline.minimumProminentFaceWidth, 0.22)
    }

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
    /// Whether the last-seen face read as too small (too far from the
    /// camera) to enroll reliably — the enroll step swaps its pose
    /// instruction for a "move closer" prompt and overlays a chevron on
    /// the preview while this is true.
    private(set) var isTooFar = false
    private(set) var enrollmentComplete = false

    /// Sectors already captured — read by EnrollmentRingView to decide which
    /// ticks are lit.
    private(set) var capturedPoses: Set<EnrollmentPose> = []
    /// Bumped every time `.center` is captured; EnrollmentRingView observes
    /// this to trigger the whole-ring pulse (center has no sector of its
    /// own to light).
    private(set) var centerPulseTick = 0

    /// Whether pose instructions should be visible in the enroll panel —
    /// false once enrollment completes, ahead of the checkmark sequence.
    private(set) var guideVisible = false
    /// Whether the camera preview should be visible — faded out as part of
    /// the camera-complete sequence.
    private(set) var cameraPreviewVisible = true
    /// Whether the completion checkmark should be drawing/shown.
    private(set) var showCheckmark = false

    private struct CollectedSample {
        let embedding: [Float]
        let pose: EnrollmentPose
        /// Carried through from `FaceRecognitionResult.quality` so an
        /// enrolled identity can report how good its samples actually were,
        /// instead of the score being read once for the accept-floor gate
        /// and then discarded.
        let quality: Float?
        /// Stamped when the frame was captured, not when it was saved.
        /// These sit in memory across the naming (and, on first run, the
        /// password) step, so a save-time stamp would date every sample of
        /// a first-run enrollment to minutes after the capture actually
        /// happened.
        let capturedAt: Date
    }
    /// Held in memory (not persisted) until the identity has a name: the
    /// naming step commits directly in the add/recapture flows, while in
    /// first-run setup saving additionally requires an unlocked session (see
    /// SecureFaceStore), and nothing unlocks it until `finish(password:)`
    /// calls `SecureCredentialManager.unlockSession` — which happens after
    /// enrollment in this flow's step order.
    private var collectedSamples: [CollectedSample] = []
    private var matchStreak = 0
    private var isProcessingFrame = false
    private var poseStartedAt: ContinuousClock.Instant = .now
    /// Set once, in `beginEnrollment()` — not per-pose — so it only holds
    /// back the very first pose (always `.center`) rather than pausing
    /// again after every later pose change.
    private var captureReadyAt: ContinuousClock.Instant = .now
    /// When the current pose first started matching continuously. `nil`
    /// while the head isn't in the requested yaw/pitch band (or the face
    /// is too far); capture waits `poseHoldDuration` past this instant.
    private var poseHoldStartedAt: ContinuousClock.Instant?

    var currentPose: EnrollmentPose? {
        EnrollmentPose(rawValue: currentPoseIndex)
    }

    /// Copy shown under the camera during enrollment — pose guidance, a
    /// closer-up prompt when the face is too small in frame, or the
    /// completion line while the checkmark plays.
    var enrollmentInstruction: String {
        if enrollmentComplete { return "Face captured" }
        if isTooFar { return "Bring your face closer" }
        return currentPose?.instruction ?? ""
    }

    private enum EnrollFrameOutcome: Sendable {
        case noFace
        case tooFar
        case ready(FaceRecognitionResult)
    }

    var overallEnrollmentProgress: Double {
        let total = Double(EnrollmentPose.allCases.count * samplesPerPose)
        let done = Double(currentPoseIndex * samplesPerPose + capturedForCurrentPose)
        return min(done / total, 1.0)
    }

    // MARK: - Naming

    /// The name being given to this enrollment — bound directly by
    /// `NameStepView`, and pre-filled by whichever entry point started the
    /// flow (the full-name default for first-run, the existing name for a
    /// recapture, empty when adding somebody new).
    var pendingName: String = ""
    private(set) var nameError: String?

    /// Naming is the last input in an add/recapture flow, but only the
    /// halfway point of first-run setup, where the password still follows.
    var nameStepPrimaryTitle: String { isEnrollmentOnly ? "Save" : "Continue" }

    // MARK: - Password

    private(set) var passwordError: String?
    private(set) var isSavingPassword = false

    init(
        isEnrollmentOnly: Bool = false,
        isPasswordOnly: Bool = false,
        enrollmentTarget: EnrollmentTarget = .newIdentity
    ) {
        self.isEnrollmentOnly = isEnrollmentOnly
        self.isPasswordOnly = isPasswordOnly
        self.enrollmentTarget = enrollmentTarget
        observeFrames()
        if isEnrollmentOnly {
            step = .enroll
            // Deferred a tick for the same reason `advance()` defers it
            // when transitioning into `.enroll` normally — see the comment
            // there.
            Task { @MainActor [weak self] in self?.beginEnrollment() }
        } else if isPasswordOnly {
            // No camera and no deferral needed: the password step starts
            // nothing heavy, so it can be the initial step outright.
            step = .password
        }
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
            case .name: break // handled by confirmName()
            case .password: break // handled by finish(password:)
            case .complete: break
            }
        }
        if leavingStep == .permissions { stopPermissionsPolling() }
        switch step {
        case .permissions: startPermissionsPolling()
        case .enroll:
            // Deferred a tick so the (comparatively heavy) camera start
            // doesn't land in the same runloop turn as the panel-resize/
            // scroll transition kicking off — doing both at once was
            // visibly stealing frames from the spring animation instead of
            // letting it start smoothly.
            Task { @MainActor [weak self] in self?.beginEnrollment() }
        default: break
        }
    }

    /// Steps backward. The enroll close control also lands here: in the
    /// full setup flow that's a retreat to pre-setup, and in add/recapture
    /// it's a cancel.
    func back() {
        navDirection = .backward
        // In the password-only flow there is no earlier step to return to —
        // stepping back into the enrollment flow (the normal behaviour
        // below) would drop the user into a setup they never started. Back
        // is a plain cancel here.
        if isPasswordOnly {
            teardown()
            NotchOverlayController.shared.dismissOnboarding()
            return
        }
        switch step {
        case .enroll where isEnrollmentOnly:
            // Nothing precedes enrollment in the add/recapture flows, and
            // unsaved samples are worthless — Close is a cancel.
            teardown()
            NotchOverlayController.shared.dismissOnboarding()
        case .enroll:
            // Full setup: discard the in-progress capture and return to
            // pre-setup. The camera has to stop here; `.enroll` is the
            // only step that owns it.
            resetEnrollmentState()
            camera.stop()
            sweepWindow.dismiss()
            withAnimation(OnboardingMetrics.stepAnimation) { step = .preSetup }
        case .password:
            // Back to naming, deliberately *without* resetting: the
            // collected samples and the typed name both survive the trip,
            // so a user who wants to fix a typo doesn't re-do nine poses.
            nameError = nil
            withAnimation(OnboardingMetrics.stepAnimation) { step = .name }
        case .name where isEnrollmentOnly:
            // Nothing precedes naming in the add/recapture flows, and
            // unsaved samples are worthless — Back is a cancel, mirroring
            // the password-only flow. Any identity being recaptured is left
            // completely untouched, since nothing is written until the name
            // is confirmed.
            teardown()
            NotchOverlayController.shared.dismissOnboarding()
        case .name:
            // Full setup: `.enroll` can't be resumed halfway, so backing
            // past it discards the capture and returns to pre-setup.
            resetEnrollmentState()
            withAnimation(OnboardingMetrics.stepAnimation) { step = .preSetup }
        default:
            guard let previous = step.previous else { return }
            withAnimation(OnboardingMetrics.stepAnimation) { step = previous }
            if step == .permissions {
                startPermissionsPolling()
            }
        }
    }

    /// Note `pendingName` deliberately survives: backing out of `.password`
    /// means re-doing the nine poses, and making the user retype a name they
    /// already chose on the way through would be gratuitous.
    private func resetEnrollmentState() {
        collectedSamples = []
        nameError = nil
        currentPoseIndex = 0
        capturedForCurrentPose = 0
        capturedPoses = []
        matchStreak = 0
        poseHoldStartedAt = nil
        isTooFar = false
        enrollmentComplete = false
        guideVisible = false
        cameraPreviewVisible = true
        showCheckmark = false
        passwordError = nil
    }

    private func beginEnrollment() {
        guard step == .enroll else { return }
        guideVisible = true
        cameraPreviewVisible = true
        showCheckmark = false
        poseStartedAt = .now
        captureReadyAt = .now + initialCaptureDelay
        poseHoldStartedAt = nil
        sweepWindow.present(for: self)
        Task { await camera.start() }
    }

    /// Tears down everything onboarding spun up: camera, sweep overlay,
    /// and permissions polling. Idempotent.
    func teardown() {
        stopPermissionsPolling()
        camera.stop()
        sweepWindow.dismiss()
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
              let cameraFrame = camera.currentFrame, let pose = currentPose else { return }
        isProcessingFrame = true
        defer { isProcessingFrame = false }

        let pipeline = self.pipeline
        let minimumWidth = enrollmentMinimumFaceWidth
        let image = cameraFrame.image
        let outcome = await Task.detached(priority: .userInitiated) {
            do {
                let faces = try FaceDetector.detectFaces(in: image)
                guard let face = FaceRecognitionPipeline.largestFace(in: faces) else {
                    return EnrollFrameOutcome.noFace
                }
                if Float(face.normalizedBoundingBox.width) < minimumWidth {
                    return EnrollFrameOutcome.tooFar
                }
                return EnrollFrameOutcome.ready(try pipeline.recognize(face, in: image))
            } catch {
                return EnrollFrameOutcome.noFace
            }
        }.value

        switch outcome {
        case .noFace:
            faceDetected = false
            currentYaw = nil
            currentPitch = nil
            matchStreak = 0
            poseHoldStartedAt = nil
            isTooFar = false
            return
        case .tooFar:
            faceDetected = true
            currentYaw = nil
            currentPitch = nil
            matchStreak = 0
            poseHoldStartedAt = nil
            isTooFar = true
            return
        case .ready(let result):
            guard let yaw = result.face.yaw, let pitch = result.face.pitch else {
                faceDetected = true
                currentYaw = nil
                currentPitch = nil
                matchStreak = 0
                poseHoldStartedAt = nil
                isTooFar = false
                return
            }
            faceDetected = true
            currentYaw = yaw
            currentPitch = pitch
            isTooFar = false
            await processMatchedEnrollFrame(result, yaw: yaw, pitch: pitch, pose: pose)
        }
    }

    private func processMatchedEnrollFrame(
        _ result: FaceRecognitionResult,
        yaw: Float,
        pitch: Float,
        pose: EnrollmentPose
    ) async {

        // Let the user settle in front of the camera before the center pose
        // starts counting — detection above still ran, so the ring's live
        // readout isn't frozen, only capture is held back.
        guard ContinuousClock.now >= captureReadyAt else {
            matchStreak = 0
            poseHoldStartedAt = nil
            return
        }

        let qualityOK = result.quality.map { $0 >= qualityFloor } ?? true
        // Only a 5-point alignment produces a reliably canonical input —
        // a 2-point or padded-crop fallback (more likely exactly during a
        // turned/tilted pose, where landmarks are harder to find) isn't
        // accepted toward enrollment.
        let alignmentOK = result.alignmentTier == .fivePoint
        let widened = ContinuousClock.now - poseStartedAt > stallTimeout
        let poseOK = poseMatches(yaw: yaw, pitch: pitch, pose: pose, widened: widened)
        guard qualityOK, alignmentOK, !isTooFar, poseOK else {
            matchStreak = 0
            poseHoldStartedAt = nil
            return
        }

        if poseHoldStartedAt == nil {
            poseHoldStartedAt = .now
        }
        guard ContinuousClock.now - poseHoldStartedAt! >= poseHoldDuration else { return }

        matchStreak += 1
        guard matchStreak >= requiredMatchStreak else { return }
        matchStreak = 0

        collectedSamples.append(CollectedSample(
            embedding: result.embedding,
            pose: pose,
            quality: result.quality,
            capturedAt: Date()
        ))
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
            poseHoldStartedAt = nil
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

    /// Runs the camera-complete sequence: pose instructions fade, camera
    /// preview fades, the checkmark draws on, then auto-advances to the
    /// naming step. Samples stay in memory here — every flow now names the
    /// identity before anything is written, and in the full setup flow
    /// persisting additionally requires the unlocked session that only
    /// `finish(password:)` produces.
    private func finishEnrollment() async {
        enrollmentComplete = true
        sweepWindow.dismiss()
        try? await Task.sleep(for: .seconds(OnboardingMetrics.guideOverlayFadeOut))

        cameraPreviewVisible = false
        try? await Task.sleep(for: .seconds(OnboardingMetrics.previewFadeOut))

        try? await Task.sleep(for: .seconds(OnboardingMetrics.checkmarkDelay))
        showCheckmark = true

        let elapsed = OnboardingMetrics.guideOverlayFadeOut + OnboardingMetrics.previewFadeOut + OnboardingMetrics.checkmarkDelay
        let remaining = max(OnboardingMetrics.cameraCompleteToNameDelay - elapsed, 0)
        try? await Task.sleep(for: .seconds(remaining))

        camera.stop()

        navDirection = .forward
        withAnimation(OnboardingMetrics.stepAnimation) { step = .name }
    }

    // MARK: - Naming

    /// Confirms the naming step. In an enrollment-only flow the session is
    /// already unlocked (the entry points guarantee it), so this is also the
    /// commit point and the flow ends here. In the full setup flow nothing
    /// can be written yet — see `finish(password:)`.
    func confirmName() {
        let trimmed = pendingName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            nameError = "Enter a name."
            return
        }
        // Skipped silently in the full setup flow, where the store is still
        // locked and `identities` is empty because it's *unreadable*, not
        // because nothing is enrolled. `finish(password:)` re-checks once
        // the session opens.
        guard !store.nameIsTaken(trimmed, excluding: enrollmentTarget.identityID) else {
            nameError = "A face named \"\(trimmed)\" is already enrolled."
            return
        }
        nameError = nil

        guard isEnrollmentOnly else {
            navDirection = .forward
            withAnimation(OnboardingMetrics.stepAnimation) { step = .password }
            return
        }

        store.reloadIfUnlocked()
        do {
            try commitEnrollment(name: trimmed)
        } catch {
            // Realistically a session that lapsed between the entry point's
            // Touch ID prompt and now. Stay on this step with the samples
            // still in memory rather than showing "You're all set" over a
            // save that didn't happen.
            nameError = error.localizedDescription
            return
        }
        navDirection = .forward
        // Ends on the same `.complete` ("You're all set") screen as the full
        // setup flow, via the same `scheduleCompletionDismiss` delay, rather
        // than dismissing the instant samples are saved — that used to
        // happen with zero confirmation that anything succeeded.
        withAnimation(OnboardingMetrics.stepAnimation) { step = .complete }
        scheduleCompletionDismiss()
    }

    /// The single place guided-enrollment samples are persisted. Requires an
    /// unlocked session; in the full setup flow that only exists once
    /// `finish(password:)` has called `SecureCredentialManager.unlockSession`.
    private func commitEnrollment(name: String) throws {
        let samples = collectedSamples.map {
            FaceSample(embedding: $0.embedding, pose: $0.pose.name, capturedAt: $0.capturedAt, quality: $0.quality)
        }
        try store.commitEnrollment(
            replacing: enrollmentTarget.identityID,
            name: name,
            samples: samples,
            embedder: pipeline.embedder
        )
    }

    /// Only a pre-fill for the first-run flow's naming step — never the
    /// stored name, which the user now always chooses themselves.
    static let defaultName: String = {
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
            // (`collectedSamples` is empty in the password-only flow, which
            // shares this method and must not try to write an identity.)
            store.reloadIfUnlocked()
            if !collectedSamples.isEmpty {
                let name = pendingName.trimmingCharacters(in: .whitespacesAndNewlines)
                // The naming step couldn't run this check — the store was
                // still locked and therefore unreadable. Bounce back rather
                // than saving over, or silently merging into, someone else.
                guard !store.nameIsTaken(name, excluding: enrollmentTarget.identityID) else {
                    nameError = "A face named \"\(name)\" is already enrolled."
                    navDirection = .backward
                    withAnimation(OnboardingMetrics.stepAnimation) { step = .name }
                    return false
                }
                try commitEnrollment(name: name)
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
