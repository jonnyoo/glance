//
//  AppLockSettingsPage.swift
//  glance
//
//  Which apps ask for a face before they can be used. Unlike the other pages this one isn't gated on Glance's session —
//  that stays unlocked for weeks — but on a fresh Touch ID / password check, since taking an app off this list is the
//  one thing the lock exists to stop a passer-by from doing.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AppLockSettingsPage: View {
    let pocController: POCController
    @Bindable private var settings = GlanceSettings.shared
    private let faceStore = FaceEnrollmentStore.shared

    @State private var isAuthorized: Bool
    @State private var isAuthenticating = false
    /// Picks from the last "add" that were turned away — Glance itself, the Finder, or something with no bundle identifier.
    @State private var rejectedNote: String?

    /// Read once: asking the system on every render would mean a fresh `LAContext` each time.
    private let offersTouchID = SystemAuthentication.offersTouchID

    init(pocController: POCController) {
        self.pocController = pocController
        // Decided once, as the page opens. With nothing locked there's nothing to prove — and adding the first app
        // mid-visit shouldn't shut the page on the person who just added it.
        let isProtecting = GlanceSettings.shared.isAppLockEnabled && !GlanceSettings.shared.lockedApps.isEmpty
        _isAuthorized = State(initialValue: !isProtecting)
    }

    private var systemPromptSubject: String {
        offersTouchID ? "Touch ID or your password" : "your password"
    }

    var body: some View {
        ZStack(alignment: .top) {
            gate
                .opacity(isAuthorized ? 0 : 1)
                .allowsHitTesting(!isAuthorized)
                .accessibilityHidden(isAuthorized)

            editor
                .opacity(isAuthorized ? 1 : 0)
                .allowsHitTesting(isAuthorized)
                .accessibilityHidden(!isAuthorized)
        }
        .animation(SettingsMetrics.stateTransitionAnimation, value: isAuthorized)
        .onAppear { pocController.refreshCredentialStatus() }
    }

    // MARK: - Gate

    private var gate: some View {
        SettingsEmptyStateView(
            icon: "lock.fill",
            message: "Locked apps are protected",
            buttonTitle: isAuthenticating ? "Authenticating…" : "Authenticate",
            isButtonEnabled: !isAuthenticating,
            caption: "Changing which apps are locked takes \(systemPromptSubject).",
            action: authenticate
        )
    }

    private func authenticate() {
        isAuthenticating = true
        Task {
            isAuthorized = await SystemAuthentication.authenticate(reason: "change which apps are locked")
            isAuthenticating = false
        }
    }

    // MARK: - Editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            SettingsGroup {
                SettingsRowContent(
                    title: "Lock apps",
                    subtitle: "Locked apps ask for your face every time you switch to them, and hide when you switch away.",
                    subtitleMaxWidth: SettingsMetrics.rowSubtitleMaxWidth
                ) {
                    GlanceToggle(isOn: $settings.isAppLockEnabled)
                }
            }

            appsHeader
                .padding(.bottom, -8)

            SettingsGroup {
                if settings.lockedApps.isEmpty {
                    SettingsRowContent(title: "No apps are locked yet") {
                        SettingsPrimaryButton(title: "Choose apps", compact: true, action: addApps)
                    }
                } else {
                    ForEach(Array(settings.lockedApps.enumerated()), id: \.element.id) { index, app in
                        if index > 0 {
                            SettingsGroupDivider()
                        }
                        LockedAppRow(app: app) { remove(app) }
                    }
                }
            }
            // Dimmed rather than hidden while switched off: the list is kept, just not enforced.
            .opacity(settings.isAppLockEnabled ? 1 : 0.45)

            if let rejectedNote {
                SettingsCaption(text: rejectedNote)
            }
            if let fallbackNote {
                SettingsCaption(text: fallbackNote)
            }
            SettingsCaption(text: "Like Face Unlock itself, this is a convenience rather than a vault: it only holds while Glance is running, and a locked app's notifications still appear.")
        }
    }

    /// Mirrors the Face page's "Identities" header, add button included.
    private var appsHeader: some View {
        HStack(spacing: 0) {
            SettingsSectionTitle(text: "Locked apps")

            Button(action: addApps) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsMetrics.textTertiary)
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Choose apps to lock")
            .padding(.trailing, SettingsMetrics.sectionTitleHorizontalInset)
            .padding(.top, SettingsMetrics.sectionTitleVerticalPadding)
        }
    }

    /// Why locked apps would currently be asking for the system prompt rather than a face, if they would — the same
    /// conditions `AppLockCoordinator.faceUnavailableReason` checks when a curtain goes up.
    private var fallbackNote: String? {
        guard settings.isAppLockEnabled, !settings.lockedApps.isEmpty else { return nil }
        if !pocController.isSessionUnlocked {
            return "Glance's session is locked, so locked apps will ask for \(systemPromptSubject) instead of your face until you unlock it."
        }
        if !faceStore.isLocked, faceStore.activeIdentities.isEmpty {
            return "No enrolled face is switched on, so locked apps will ask for \(systemPromptSubject) instead."
        }
        return nil
    }

    // MARK: - Actions

    private func addApps() {
        let panel = NSOpenPanel()
        panel.message = "Choose the apps that should ask for your face."
        panel.prompt = "Lock"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK else { return }

        var apps = settings.lockedApps
        var rejected: [String] = []
        for url in panel.urls {
            guard let app = LockedApp(bundleURL: url) else {
                rejected.append(LockedApp.displayName(for: url))
                continue
            }
            if !apps.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) {
                apps.append(app)
            }
        }
        // One assignment, so `AppLockCoordinator` sees a single change however many apps were picked.
        if apps != settings.lockedApps {
            settings.lockedApps = apps
        }
        rejectedNote = rejected.isEmpty
            ? nil
            : "\(ListFormatter.localizedString(byJoining: rejected)) can't be locked."
    }

    private func remove(_ app: LockedApp) {
        settings.lockedApps.removeAll { $0.id == app.id }
    }
}

// MARK: - Row

/// One locked app: icon, name, and a remove control styled after the Face page's delete button.
private struct LockedAppRow: View {
    let app: LockedApp
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: app.icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)

            Text(app.name)
                .font(SettingsMetrics.rowFont)
                .foregroundStyle(SettingsMetrics.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: 8)

            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(SettingsMetrics.textPrimary)
                    .frame(width: 24, height: 24)
                    .background(SettingsMetrics.neutralButtonFill)
                    .overlay(
                        Circle().strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
                    )
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Stop locking \(app.name)")
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
        .frame(minHeight: SettingsMetrics.rowHeight)
    }
}
