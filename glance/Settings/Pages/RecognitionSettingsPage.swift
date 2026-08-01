//
//  RecognitionSettingsPage.swift
//  glance
//

import SwiftUI

struct RecognitionSettingsPage: View {
    @Bindable var coordinator: FaceUnlockCoordinator
    let faceLabController: FaceLabController
    @Bindable private var settings = GlanceSettings.shared

    var body: some View {
        SettingsSlider(
            title: "Match threshold",
            subtitle: "How similar a live face must be to your enrolled face to count as a match. Lower is more lenient, higher is stricter.",
            value: $coordinator.matchThreshold,
            range: -1...1
        )

        if let suggested = faceLabController.suggestedThreshold {
            SettingsActionRow(
                title: "Face Lab suggests \(String(format: "%.2f", suggested))",
                subtitle: "Based on calibration samples recorded in the Face Lab debug tab this session.",
                buttonTitle: "Use This Value"
            ) {
                coordinator.matchThreshold = suggested
            }
        }

        SettingsSlider(
            title: "Minimum face size",
            subtitle: "How large a face must appear in frame to be considered. Lower values also recognize faces farther from the camera, but make it easier for someone in the background to be picked up by mistake.",
            value: $settings.minimumFaceWidth,
            range: 0.05...0.6
        )
    }
}
