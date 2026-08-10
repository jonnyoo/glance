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
}
