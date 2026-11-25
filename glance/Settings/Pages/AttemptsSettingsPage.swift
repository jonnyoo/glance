//
//  AttemptsSettingsPage.swift
//  glance
//
//  "Who tried?" — photos of failed unlock attempts from `AttemptLog`, newest first.
//

import SwiftUI
import AppKit

struct AttemptsSettingsPage: View {
    @Bindable private var settings = GlanceSettings.shared
    @State private var attempts: [AttemptLog.Attempt] = []

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingsGroup {
                SettingsRowContent(
                    title: String(localized: "Save photos of failed attempts"),
                    subtitle: String(localized: "Takes a photo when a face that isn't enrolled, or a photo of one, tries to unlock your Mac. Photos stay on this Mac."),
                    subtitleMaxWidth: SettingsMetrics.rowSubtitleMaxWidth
                ) {
                    GlanceToggle(isOn: $settings.saveAttemptPhotos)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                SettingsSectionTitle(text: String(localized: "Recent attempts"))
                if attempts.isEmpty {
                    SettingsCaption(text: String(localized: "No failed attempts yet."))
                        .padding(.leading, SettingsMetrics.sectionTitleHorizontalInset)
                } else {
                    SettingsGroup {
                        ForEach(Array(attempts.enumerated()), id: \.element.id) { index, attempt in
                            if index > 0 {
                                SettingsGroupDivider()
                            }
                            AttemptRow(attempt: attempt) { AttemptLog.delete(attempt) }
                        }
                    }
                    SettingsGroup {
                        SettingsRowContent(title: String(localized: "Delete all attempts")) {
                            HoldToConfirmButton(title: String(localized: "Remove")) { AttemptLog.deleteAll() }
                        }
                    }
                }
            }
        }
        .onAppear {
            reload()
            settings.attemptsLastSeenAt = Date()
        }
        .onReceive(NotificationCenter.default.publisher(for: .attemptLogDidChange)) { _ in reload() }
    }

    private func reload() {
        attempts = AttemptLog.list()
    }
}

/// Thumbnail (click for a larger popover), kind and time, and a delete button.
private struct AttemptRow: View {
    let attempt: AttemptLog.Attempt
    let onDelete: () -> Void
    @State private var image: NSImage?
    @State private var isPreviewing = false

    var body: some View {
        HStack(spacing: 12) {
            Button { isPreviewing = true } label: { thumbnail }
                .buttonStyle(.plain)
                .help(String(localized: "Show photo"))
                .popover(isPresented: $isPreviewing, arrowEdge: .trailing) {
                    if let image {
                        Image(nsImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 480)
                            .padding(8)
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SettingsMetrics.rowFont)
                    .foregroundStyle(SettingsMetrics.textPrimary)
                Text(attempt.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsMetrics.textTertiary)
            }

            Spacer(minLength: 8)

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsMetrics.textPrimary)
                    .frame(width: 28, height: 28)
                    .background(SettingsMetrics.neutralButtonFill)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help(String(localized: "Delete this attempt"))
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
        .padding(.vertical, 8)
        .task(id: attempt.url) {
            image = NSImage(contentsOf: attempt.url)
        }
    }

    private var title: String {
        switch attempt.kind {
        case .unrecognized: return String(localized: "Unrecognized face")
        case .spoof: return String(localized: "Spoof attempt")
        }
    }

    private var thumbnail: some View {
        ZStack {
            SettingsMetrics.optionPreviewFill
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .frame(width: 64, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
