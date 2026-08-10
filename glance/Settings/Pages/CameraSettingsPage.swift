//
//  CameraSettingsPage.swift
//  glance
//

import SwiftUI

struct CameraSettingsPage: View {
    @State private var devices: [CameraDevice] = CameraDeviceCatalog.availableDevices()
    @Bindable private var settings = GlanceSettings.shared
    @State private var previewCamera = CameraManager()

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingsCaption(text: "Choose which camera Glance uses for face recognition. Set a single default, or override it separately for when you're using your MacBook's built-in display vs. an external one.")

            cameraPicker(title: "Default camera", selection: $settings.defaultCameraID)
            cameraPicker(title: "When using built-in display", selection: $settings.builtInDisplayCameraID)
            cameraPicker(title: "When using external display", selection: $settings.externalDisplayCameraID)

            Button("Refresh camera list") {
                devices = CameraDeviceCatalog.availableDevices()
            }
            .buttonStyle(.plain)
            .font(.system(size: 12))
            .foregroundStyle(GlanceTheme.accent)

            CameraPreviewView(session: previewCamera.session, faces: [])
                .frame(height: 160)
                .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius)
                        .strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
                )

            if let error = previewCamera.errorMessage {
                SettingsCaption(text: error)
            }
        }
        .onAppear { Task { await previewCamera.start() } }
        .onDisappear { previewCamera.stop() }
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
        SettingsRow(title: title) {
            Picker("", selection: selection) {
                Text("System default").tag(String?.none)
                ForEach(devices) { device in
                    Text(device.name).tag(String?.some(device.id))
                }
            }
            .labelsHidden()
            .frame(width: 200)
        }
    }
}
