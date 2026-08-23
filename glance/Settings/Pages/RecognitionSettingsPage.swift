//
//  RecognitionSettingsPage.swift
//  glance
//
//  Gated behind the same Touch-ID session as Password/Your Face: match
//  confidence and detection distance are recognition-tuning knobs, and
//  changing them while locked would be adjusting how face unlock behaves
//  without having proven you're allowed to touch it at all.
//

import SwiftUI

struct RecognitionSettingsPage: View {
    @Bindable var coordinator: FaceUnlockCoordinator
    @Bindable var pocController: POCController
    @Bindable private var settings = GlanceSettings.shared

    @State private var isUnlocking = false
    @State private var sessionError: String?

    /// Read from `POCController` rather than a local `@State` copy — same
    /// reasoning as `PasswordSettingsPage`: the session can lock itself out
    /// from under this page (`SessionAutoLocker`, or the Password tab's
    /// "Remove password"), and a local copy wouldn't notice.
    private var isSessionUnlocked: Bool { pocController.isSessionUnlocked }

    var body: some View {
        ZStack(alignment: .top) {
            lockedState
                .opacity(isSessionUnlocked ? 0 : 1)
                .allowsHitTesting(!isSessionUnlocked)
                .accessibilityHidden(isSessionUnlocked)

            unlockedState
                .opacity(isSessionUnlocked ? 1 : 0)
                .allowsHitTesting(isSessionUnlocked)
                .accessibilityHidden(!isSessionUnlocked)
        }
        .animation(SettingsMetrics.stateTransitionAnimation, value: isSessionUnlocked)
        .onAppear { pocController.refreshCredentialStatus() }
        // Password/name/enrollment flows run in the notch, entirely
        // outside this window — this page never disappears while one is
        // open, so nothing else would prompt a re-check once it closes.
        .onChange(of: NotchOverlayController.shared.phase) { _, newPhase in
            guard newPhase == .closed else { return }
            pocController.refreshCredentialStatus()
        }
    }

    // MARK: - Locked

    private var lockedState: some View {
        SettingsEmptyStateView(
            icon: "lock.fill",
            message: "Session locked",
            buttonTitle: isUnlocking ? "Authenticating…" : "Unlock session",
            isButtonEnabled: !isUnlocking,
            caption: sessionError,
            action: unlock
        )
    }

    // MARK: - Unlocked

    private var unlockedState: some View {
        SettingsGroup {
            SettingsSteppedSliderRowContent(
                title: "Match confidence",
                valueLabel: matchConfidenceLevel.title,
                index: matchConfidenceIndex,
                stopCount: MatchConfidenceLevel.allCases.count
            )

            SettingsGroupDivider()

            SettingsSteppedSliderRowContent(
                title: "Detection distance",
                valueLabel: detectionDistanceLevel.title,
                index: detectionDistanceIndex,
                stopCount: DetectionDistanceLevel.allCases.count
            )

            SettingsGroupDivider()

            SettingsSteppedSliderRowContent(
                title: "Liveness strictness",
                valueLabel: livenessStrictnessLevel.title,
                index: livenessStrictnessIndex,
                stopCount: LivenessStrictnessLevel.allCases.count
            )
        }
    }

    // MARK: - Match confidence

    /// Nearest of the three snap points to whatever's actually stored —
    /// covers a threshold saved before this redesign (the old slider was
    /// continuous across -1...1), which won't land exactly on 0.66/0.70/0.74.
    private var matchConfidenceLevel: MatchConfidenceLevel {
        .nearest(to: coordinator.matchThreshold)
    }

    private var matchConfidenceIndex: Binding<Double> {
        Binding(
            get: { matchConfidenceLevel.sliderIndex },
            set: { coordinator.matchThreshold = MatchConfidenceLevel.from(sliderIndex: $0).threshold }
        )
    }

    // MARK: - Detection distance

    private var detectionDistanceLevel: DetectionDistanceLevel {
        .nearest(to: settings.minimumFaceWidth)
    }

    private var detectionDistanceIndex: Binding<Double> {
        Binding(
            get: { detectionDistanceLevel.sliderIndex },
            set: { settings.minimumFaceWidth = DetectionDistanceLevel.from(sliderIndex: $0).minimumFaceWidth }
        )
    }

    // MARK: - Liveness strictness

    private var livenessStrictnessLevel: LivenessStrictnessLevel {
        .nearest(to: settings.livenessThreshold)
    }

    private var livenessStrictnessIndex: Binding<Double> {
        Binding(
            get: { livenessStrictnessLevel.sliderIndex },
            set: { settings.livenessThreshold = LivenessStrictnessLevel.from(sliderIndex: $0).threshold }
        )
    }

    // MARK: - Actions

    private func unlock() {
        isUnlocking = true
        sessionError = nil
        Task {
            await pocController.unlockSession()
            sessionError = pocController.sessionError
            isUnlocking = false
        }
    }
}

/// The three selectable points on the "Match confidence" slider — named
/// rather than exposing the raw cosine-similarity threshold directly, since
/// a number in -1...1 means nothing to someone tuning how strict face
/// unlock should be.
private enum MatchConfidenceLevel: Int, CaseIterable {
    case lessStrict, standard, moreStrict

    var title: String {
        switch self {
        case .lessStrict: return "Less strict"
        case .standard: return "Default"
        case .moreStrict: return "More strict"
        }
    }

    var threshold: Float {
        switch self {
        case .lessStrict: return 0.64
        case .standard: return 0.68
        case .moreStrict: return 0.72
        }
    }

    /// Position in `allCases` — same role as `AutoLockInterval.sliderIndex`.
    var sliderIndex: Double {
        Double(Self.allCases.firstIndex(of: self) ?? 0)
    }

    static func from(sliderIndex: Double) -> Self {
        let clamped = Int(sliderIndex.rounded())
        return allCases.indices.contains(clamped) ? allCases[clamped] : .standard
    }

    static func nearest(to threshold: Float) -> Self {
        allCases.min { abs($0.threshold - threshold) < abs($1.threshold - threshold) } ?? .standard
    }
}

/// The three selectable points on the "Detection distance" slider.
private enum DetectionDistanceLevel: Int, CaseIterable {
    case close, standard, far

    var title: String {
        switch self {
        case .close: return "Close"
        case .standard: return "Default"
        case .far: return "Far"
        }
    }

    var minimumFaceWidth: Float {
        switch self {
        case .close: return 0.25
        case .standard: return 0.21
        case .far: return 0.17
        }
    }

    var sliderIndex: Double {
        Double(Self.allCases.firstIndex(of: self) ?? 0)
    }

    static func from(sliderIndex: Double) -> Self {
        let clamped = Int(sliderIndex.rounded())
        return allCases.indices.contains(clamped) ? allCases[clamped] : .standard
    }

    static func nearest(to width: Float) -> Self {
        allCases.min { abs($0.minimumFaceWidth - width) < abs($1.minimumFaceWidth - width) } ?? .standard
    }
}

/// The three selectable points on the "Liveness strictness" slider — how
/// hard `LivenessAnalyzer` (glance/Liveness/) makes it to pass the
/// non-rigid-motion check that stands between a live face and a static
/// photo. Higher rejects more spoofs but raises the false-reject rate for
/// a legitimate user sitting very still or in poor light; there's no
/// single right answer, hence tunable rather than fixed. Starting points
/// pending empirical calibration in Face Lab, same as `MatchConfidenceLevel`.
private enum LivenessStrictnessLevel: Int, CaseIterable {
    case convenience, balanced, security

    var title: String {
        switch self {
        case .convenience: return "Convenience"
        case .balanced: return "Balanced"
        case .security: return "Security"
        }
    }

    var threshold: Float {
        switch self {
        case .convenience: return 0.71
        case .balanced: return 0.74
        case .security: return 0.77
        }
    }

    var sliderIndex: Double {
        Double(Self.allCases.firstIndex(of: self) ?? 0)
    }

    static func from(sliderIndex: Double) -> Self {
        let clamped = Int(sliderIndex.rounded())
        return allCases.indices.contains(clamped) ? allCases[clamped] : .balanced
    }

    static func nearest(to threshold: Float) -> Self {
        allCases.min { abs($0.threshold - threshold) < abs($1.threshold - threshold) } ?? .balanced
    }
}
