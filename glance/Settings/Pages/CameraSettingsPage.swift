//
//  CameraSettingsPage.swift
//  glance
//

import SwiftUI

struct CameraSettingsPage: View {
    @Bindable var pocController: POCController
    @State private var devices: [CameraDevice] = CameraDeviceCatalog.availableDevices()
    @Bindable private var settings = GlanceSettings.shared
    @State private var previewCamera = CameraManager()
    @State private var isPreviewShown = false

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
        // Gated on isSessionUnlocked so the header's refresh icon doesn't
        // show while this page is displaying the locked prompt.
        .preference(
            key: HeaderTrailingActionKey.self,
            value: isSessionUnlocked ? HeaderAction(perform: refreshDevices) : nil
        )
        .onAppear { pocController.refreshCredentialStatus() }
        .onChange(of: isSessionUnlocked) { _, unlocked in
            guard !unlocked else { return }
            hidePreview()
        }
        .onDisappear { hidePreview() }
        // Password/name/enrollment flows run in the notch, outside this
        // window, so nothing else prompts a re-check once one closes.
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
            Toggle("Allow iPhone cameras", isOn: $settings.allowContinuityCamera)
            SettingsGroup {
                cameraPicker(title: "Default", selection: $settings.defaultCameraID)
                SettingsGroupDivider()
                cameraPicker(title: "Built-in display", selection: $settings.builtInDisplayCameraID)
                SettingsGroupDivider()
                cameraPicker(title: "External display", selection: $settings.externalDisplayCameraID)
            }

            SettingsSectionTitle(text: "Preview")
            .padding(.bottom, -4)
            previewArea
                .frame(height: 220)
                .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius)
                        .strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
                )

            if isPreviewShown, let error = previewCamera.errorMessage {
                SettingsCaption(text: error)
            }
        }
        .onChange(of: settings.allowContinuityCamera) {
            refreshDevices()
            restartPreview()
        }
        .onChange(of: settings.defaultCameraID) { restartPreview() }
        .onChange(of: settings.builtInDisplayCameraID) { restartPreview() }
        .onChange(of: settings.externalDisplayCameraID) { restartPreview() }
    }

    /// Live feed, or a placeholder until "Show preview" is tapped — opening
    /// this page alone should never request camera access.
    @ViewBuilder
    private var previewArea: some View {
        if isPreviewShown {
            CameraPreviewView(session: previewCamera.session, faces: [])
        } else {
            ZStack {
                SettingsMetrics.rowColor
                SettingsPrimaryButton(title: "Show preview", action: showPreview)
            }
        }
    }

    private func showPreview() {
        isPreviewShown = true
        Task { await previewCamera.start() }
    }

    private func hidePreview() {
        guard isPreviewShown else { return }
        previewCamera.stop()
        isPreviewShown = false
    }

    /// `CameraManager` only re-resolves its device on `start()`, so restart
    /// it to reflect a new pick. No-op while hidden — picking a camera must
    /// not be what quietly turns it on.
    private func restartPreview() {
        guard isPreviewShown else { return }
        previewCamera.stop()
        Task { await previewCamera.start() }
    }

    private func cameraPicker(title: String, selection: Binding<String?>) -> some View {
        SettingsRowContent(title: title) {
            SettingsMenuPickerPill(label: cameraLabel(for: selection.wrappedValue)) {
                Button("System default") { selection.wrappedValue = nil }
                ForEach(devices) { device in
                    Button(device.name) { selection.wrappedValue = device.id }
                }
            }
        }
    }

    /// Fired by the header's refresh icon (see `HeaderTrailingActionKey`).
    private func refreshDevices() {
        devices = CameraDeviceCatalog.availableDevices()
    }

    private func cameraLabel(for id: String?) -> String {
        guard let id else { return "System default" }
        return devices.first(where: { $0.id == id })?.name ?? "Selected camera unavailable"
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
