//
//  CameraSettingsPage.swift
//  glance
//
//  Gated behind the same Touch-ID session as Password/Your Face/Recognition
//  — same reasoning as Recognition: picking which camera face unlock uses
//  is part of that same trust boundary. The live preview additionally stops
//  itself whenever the page isn't unlocked, not just when it isn't visible
//  — a running camera feed sitting behind a "Session locked" prompt would
//  defeat the point of the lock.
//

import SwiftUI

struct CameraSettingsPage: View {
    @Bindable var pocController: POCController
    @State private var devices: [CameraDevice] = CameraDeviceCatalog.availableDevices()
    @Bindable private var settings = GlanceSettings.shared
    @State private var previewCamera = CameraManager()

    @State private var isUnlocking = false
    @State private var sessionError: String?

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
        .onAppear {
            pocController.refreshCredentialStatus()
            // Covers landing on this page already unlocked — `onChange`
            // below only fires on a *transition*, so it wouldn't otherwise
            // start the preview for a session that was open before this
            // view ever appeared.
            if isSessionUnlocked {
                Task { await previewCamera.start() }
            }
        }
        .onChange(of: isSessionUnlocked) { _, unlocked in
            if unlocked {
                Task { await previewCamera.start() }
            } else {
                previewCamera.stop()
            }
        }
        .onDisappear { previewCamera.stop() }
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
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingsGroup {
                cameraPicker(title: "Default", selection: $settings.defaultCameraID)
                SettingsGroupDivider()
                cameraPicker(title: "Built-in display", selection: $settings.builtInDisplayCameraID)
                SettingsGroupDivider()
                cameraPicker(title: "External display", selection: $settings.externalDisplayCameraID)
            }

            HStack {
                Spacer(minLength: 0)
                Button("Refresh camera list") {
                    devices = CameraDeviceCatalog.availableDevices()
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(GlanceTheme.textSecondary)
                .padding(.top, -4)
            }
            .padding(.trailing, SettingsMetrics.rowHorizontalInset)

            SettingsSectionTitle(text: "Preview")
            CameraPreviewView(session: previewCamera.session, faces: [])
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius)
                        .strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
                )

            if let error = previewCamera.errorMessage {
                SettingsCaption(text: error)
            }
        }
        .onChange(of: settings.defaultCameraID) { restartPreview() }
        .onChange(of: settings.builtInDisplayCameraID) { restartPreview() }
        .onChange(of: settings.externalDisplayCameraID) { restartPreview() }
    }

    /// `CameraManager` only re-resolves its device when `start()` runs, so
    /// picking a new camera here restarts the preview session to show the
    /// change immediately rather than waiting for the next natural start.
    private func restartPreview() {
        previewCamera.stop()
        Task { await previewCamera.start() }
    }

    private func cameraPicker(title: String, selection: Binding<String?>) -> some View {
        SettingsRowContent(title: title) {
            // Capsule chrome sits *behind* the Menu — macOS Menu labels
            // discard backgrounds applied inside the label hierarchy.
            ZStack {
                Capsule()
                    .fill(SettingsMetrics.pickerPillFill)

                Menu {
                    Button("System default") { selection.wrappedValue = nil }
                    ForEach(devices) { device in
                        Button(device.name) { selection.wrappedValue = device.id }
                    }
                } label: {
                    HStack(spacing: 6) {
                        Text(cameraLabel(for: selection.wrappedValue))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(SettingsMetrics.textPrimary)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 7, weight: .semibold))
                            .foregroundStyle(SettingsMetrics.textSecondary)
                    }
                    .font(.system(size: 11))
                    .padding(.horizontal, 8)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Capsule())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .buttonStyle(.plain)
                // Window-level accent tint otherwise paints the menu label blue.
                .tint(SettingsMetrics.textPrimary)
            }
            .frame(width: 160, height: 28)
            .overlay {
                Capsule()
                    .strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
            }
        }
    }

    private func cameraLabel(for id: String?) -> String {
        guard let id, let device = devices.first(where: { $0.id == id }) else {
            return "System default"
        }
        return device.name
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
