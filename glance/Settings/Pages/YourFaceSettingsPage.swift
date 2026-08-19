//
//  YourFaceSettingsPage.swift
//  glance
//
//  The multi-identity Your Face page (Figma node 121:3). Every enrolled
//  person gets a card: their name, a switch that takes them in or out of
//  face unlock, a strip of per-sample capture-quality ticks, and Recapture /
//  Delete. The card chrome deliberately reuses `SettingsGroup` and the
//  `SettingsMetrics` row tokens rather than the Figma frame's raw hexes, so
//  this page stays in step with General/Password/Camera in both appearances.
//
//  The locked and not-enrolled states are unchanged — the redesign only
//  replaces what the page shows once identities are actually readable.
//

import SwiftUI

struct YourFaceSettingsPage: View {
    let environment: AppEnvironment
    @Bindable private var store = FaceEnrollmentStore.shared

    @State private var sessionError: String?
    @State private var isUnlocking = false
    @State private var identityPendingDeletion: FaceIdentity?
    /// Surfaced when an encrypted write fails (realistically: the session
    /// lapsed between rendering and tapping). The store rolls its in-memory
    /// state back on failure, so the control snaps back on its own — this
    /// just explains why.
    @State private var writeError: String?

    /// Locked takes priority over enrollment status for a reason specific to
    /// this store, not just copied from Password's page: `FaceIdentity` data
    /// is encrypted under the session key (see `FaceEnrollmentStore
    /// .reloadIfUnlocked`), so whether anyone is enrolled is simply *unknown*
    /// until the session is unlocked — unlike a stored password, whose
    /// existence is a plain Keychain check needing no decryption at all.
    /// There is no way to show "not enrolled" before that.
    private enum PageStateKind: Equatable {
        case locked
        case notEnrolled
        case enrolled
    }

    private var stateKind: PageStateKind {
        if store.isLocked { return .locked }
        return store.identities.isEmpty ? .notEnrolled : .enrolled
    }

    /// The notch hosts one flow at a time, so a second Add/Recapture would
    /// swap the content out from under a capture already in progress.
    private var enrollmentFlowIsRunning: Bool {
        NotchOverlayController.shared.phase == .onboarding
    }

    var body: some View {
        ZStack(alignment: .top) {
            lockedState
                .opacity(stateKind == .locked ? 1 : 0)
                .allowsHitTesting(stateKind == .locked)
                .accessibilityHidden(stateKind != .locked)

            notEnrolledState
                .opacity(stateKind == .notEnrolled ? 1 : 0)
                .allowsHitTesting(stateKind == .notEnrolled)
                .accessibilityHidden(stateKind != .notEnrolled)

            enrolledState
                .opacity(stateKind == .enrolled ? 1 : 0)
                .allowsHitTesting(stateKind == .enrolled)
                .accessibilityHidden(stateKind != .enrolled)
        }
        .animation(SettingsMetrics.stateTransitionAnimation, value: stateKind)
        .onAppear { store.reloadIfUnlocked() }
        // The enrollment flow runs in the notch, entirely outside this
        // window's view hierarchy — this view never disappears while it's
        // open, so nothing else would prompt a re-check once it closes.
        // Without this, finishing "Set up FaceID" (or a recapture) would
        // leave this page on its old state until the user happened to
        // switch tabs and back.
        .onChange(of: NotchOverlayController.shared.phase) { _, newPhase in
            guard newPhase == .closed else { return }
            store.reloadIfUnlocked()
        }
        .confirmationDialog(
            "Delete this enrolled face?",
            isPresented: Binding(
                get: { identityPendingDeletion != nil },
                set: { if !$0 { identityPendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: identityPendingDeletion
        ) { identity in
            Button("Delete", role: .destructive) { delete(identity) }
            Button("Cancel", role: .cancel) { identityPendingDeletion = nil }
        } message: { identity in
            Text("\"\(identity.name)\" will stop being recognized until you enroll them again.")
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

    // MARK: - Not enrolled

    private var notEnrolledState: some View {
        SettingsEmptyStateView(
            icon: "faceid",
            message: "Face enrollment",
            buttonTitle: "Set up FaceID",
            isButtonEnabled: !enrollmentFlowIsRunning,
            action: { OnboardingController.startEnrollmentOnly() }
        )
    }

    // MARK: - Enrolled

    private var enrolledState: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            faceEncryptedCard
            identitiesHeader
            .padding(.bottom, -8)

            ForEach(store.identities) { identity in
                IdentityCard(
                    identity: identity,
                    isStale: identity.isStale(comparedTo: environment.faceLabController.pipeline.embedder),
                    canStartFlow: !enrollmentFlowIsRunning,
                    isEnabled: enabledBinding(for: identity),
                    recapture: { OnboardingController.startRecapture(of: identity) },
                    delete: { identityPendingDeletion = identity }
                )
            }

            // Every switch off is a legitimate state to be in, but it makes
            // face unlock silently match nobody — worth saying out loud
            // rather than leaving the user to wonder why it stopped.
            if !store.identities.isEmpty && store.activeIdentities.isEmpty {
                SettingsCaption(text: "No identities are enabled — face unlock won't recognize anyone until you switch one back on.")
            }

            if let writeError {
                SettingsCaption(text: writeError)
            }
        }
    }

    /// Mirrors the Password page's "Password encrypted" row — same
    /// `lock.fill` glyph, same weight — since both are saying the same thing
    /// about the same session key.
    private var faceEncryptedCard: some View {
        SettingsGroup {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("Face encrypted")
                        .font(SettingsMetrics.rowFont)
                        .foregroundStyle(SettingsMetrics.textPrimary)
                    Spacer(minLength: 8)
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsMetrics.textSecondary)
                }

                Text("Enroll separate identities to use FaceID with multiple people, accessories (ex. glasses), facial expressions, or new lighting environments. This improves recognition quality.")
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsMetrics.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
            .padding(.vertical, 12)
        }
    }

    private var identitiesHeader: some View {
        HStack(spacing: 0) {
            SettingsSectionTitle(text: "Identities")

            Button {
                OnboardingController.startAddIdentity()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsMetrics.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(enrollmentFlowIsRunning)
            .opacity(enrollmentFlowIsRunning ? 0.4 : 1)
            .help("Enroll another face")
            .padding(.trailing, SettingsMetrics.sectionTitleHorizontalInset)
            .padding(.top, SettingsMetrics.sectionTitleVerticalPadding)
        }
    }

    // MARK: - Actions

    /// Reads through to the store rather than capturing the row's snapshot,
    /// so the switch reflects a rolled-back write instead of the value the
    /// user just tapped.
    private func enabledBinding(for identity: FaceIdentity) -> Binding<Bool> {
        Binding(
            get: { store.identities.first { $0.id == identity.id }?.isEnabled ?? true },
            set: { newValue in
                do {
                    try store.setEnabled(newValue, for: identity.id)
                    writeError = nil
                } catch {
                    writeError = error.localizedDescription
                }
            }
        )
    }

    private func delete(_ identity: FaceIdentity) {
        do {
            try store.delete(identity)
            writeError = nil
        } catch {
            writeError = error.localizedDescription
        }
        identityPendingDeletion = nil
    }

    private func unlock() {
        isUnlocking = true
        sessionError = nil
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try SecureCredentialManager.unlockSession(reason: "Authenticate to view your enrolled face")
                }.value
                store.reloadIfUnlocked()
            } catch {
                sessionError = error.localizedDescription
            }
            isUnlocking = false
        }
    }
}

// MARK: - Identity card

/// One enrolled person. Laid out as the Figma frame has it — name pill and
/// switch on the first line, the quality read-out and its actions on the
/// second — but built from `SettingsGroup` and the shared row tokens so the
/// fills, radii, and hairline borders match every other settings page.
private struct IdentityCard: View {
    let identity: FaceIdentity
    let isStale: Bool
    let canStartFlow: Bool
    @Binding var isEnabled: Bool
    let recapture: () -> Void
    let delete: () -> Void

    private var poorCount: Int {
        identity.samples.filter { $0.qualityTier == .poor }.count
    }

    private var ratedCount: Int {
        identity.samples.filter { $0.qualityTier != .unrated }.count
    }

    /// "3/18 low" counts only the red band, matching the tick colors right
    /// beneath it. An enrollment saved before per-sample quality existed has
    /// nothing to report — saying "0/18 low" there would read as a clean
    /// bill of health for samples that were never measured.
    private var qualityCaption: String {
        if identity.samples.isEmpty { return "No samples captured" }
        if ratedCount == 0 { return "Capture quality • not recorded" }
        return "Capture quality • \(poorCount)/\(identity.samples.count) low"
    }

    var body: some View {
        SettingsGroup {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 8) {
                    namePill
                    .padding(.leading, -2)
                    Spacer(minLength: 8)
                    GlanceToggle(isOn: $isEnabled)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(qualityCaption)
                        .font(.system(size: 12))
                        .foregroundStyle(SettingsMetrics.textTertiary)

                    HStack(alignment: .center, spacing: 8) {
                        QualityTickStrip(samples: identity.samples)
                        .padding(.leading, 2)
                        Spacer(minLength: 12)
                        PillActionButton(title: "Recapture", action: recapture)
                            .disabled(!canStartFlow)
                            .opacity(canStartFlow ? 1 : 0.4)
                        PillIconButton(systemImage: "trash", action: delete)
                            .help("Delete \(identity.name)")
                    }
                }
                // Dimmed rather than hidden while switched off: the person
                // is still enrolled, just not being matched against.
                .opacity(isEnabled ? 1 : 0.45)

                if isStale {
                    Text("Captured with a different recognition model — recapture before this face can unlock your Mac.")
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsMetrics.qualityFairColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
            .padding(.vertical, 12)
        }
    }

    private var namePill: some View {
        Text(identity.name)
            .font(SettingsMetrics.rowFont)
            .foregroundStyle(SettingsMetrics.textPrimary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(SettingsMetrics.buttonBackgroundColor)
            .overlay(
                Capsule().strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
            )
            .clipShape(Capsule())
            .opacity(isEnabled ? 1 : 0.45)
    }
}

/// One tick per stored sample, colored by its band. Reads left-to-right in
/// capture order (not sorted by score) so a run of red points at the pose
/// that actually went badly, which is the thing a recapture would fix.
private struct QualityTickStrip: View {
    let samples: [FaceSample]

    var body: some View {
        HStack(spacing: SettingsMetrics.qualityTickSpacing) {
            ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                Capsule()
                    .fill(color(for: sample.qualityTier))
                    // A max (not a fixed) width so an identity with far more
                    // samples than a guided enrollment's 18 compresses its
                    // ticks instead of overflowing the card.
                    .frame(maxWidth: SettingsMetrics.qualityTickWidth)
            }
        }
        .frame(width: stripWidth, height: SettingsMetrics.qualityTickHeight, alignment: .leading)
        .accessibilityElement()
        .accessibilityLabel("Capture quality for \(samples.count) samples")
    }

    /// Fixed rather than flexible: this strip shares a row with a `Spacer`
    /// and two buttons, and a `maxWidth` frame would negotiate against them
    /// for the slack instead of just sizing to its ticks. Past the cap the
    /// width stops growing and the ticks compress inside it.
    private var stripWidth: CGFloat {
        let tick = SettingsMetrics.qualityTickWidth
        let gap = SettingsMetrics.qualityTickSpacing
        let natural = CGFloat(samples.count) * (tick + gap) - gap
        return min(max(natural, 0), SettingsMetrics.qualityStripMaxWidth)
    }

    private func color(for tier: FaceSample.QualityTier) -> Color {
        switch tier {
        case .poor: return SettingsMetrics.qualityPoorColor
        case .fair: return SettingsMetrics.qualityFairColor
        case .good: return SettingsMetrics.qualityGoodColor
        case .unrated: return SettingsMetrics.qualityUnratedColor
        }
    }
}

/// Neutral capsule button matching the card's inner pills — the Figma
/// "Recapture" control. Deliberately not `SettingsPrimaryButton`: this sits
/// next to a destructive action and shouldn't read as the accent CTA.
private struct PillActionButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(SettingsMetrics.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(SettingsMetrics.buttonBackgroundColor)
                .overlay(
                    Capsule().strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
                )
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// The circular icon twin of `PillActionButton`, for the delete control.
private struct PillIconButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12))
                .foregroundStyle(SettingsMetrics.textPrimary)
                .frame(width: 28, height: 28)
                .background(SettingsMetrics.neutralButtonFill)
                .overlay(
                    Circle().strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
                )
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
