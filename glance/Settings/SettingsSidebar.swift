//
//  SettingsSidebar.swift
//  glance
//
//  A fixed, non-collapsible sidebar — plain VStack of buttons rather than
//  NavigationSplitView, deliberately: NavigationSplitView's sidebar can be
//  collapsed by the user, which the design explicitly doesn't want.
//

import SwiftUI

struct SettingsSidebar: View {
    @Binding var selection: SettingsTab
    @Bindable var pocController: POCController
    /// Whether the Debug/Face Lab section should render at all — see
    /// `AppEnvironment.isDebugSectionRevealed`. Hidden by default; this view
    /// has no way to reveal it itself, only to reflect what's already true.
    let isDebugSectionRevealed: Bool

    @State private var isUnlocking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Empty reserved band, not a view: the traffic lights here are
            // the window's real ones, drawn by AppKit in the titlebar area
            // that our content extends underneath (see
            // WindowConfiguringView). Nothing of ours may sit in this strip
            // or it would render on top of them.
            Color.clear
                .frame(height: SettingsMetrics.trafficLightBandHeight)

            // Plain VStack, not a ScrollView — the design wants a fixed,
            // non-scrolling sidebar, and the full tab list comfortably fits
            // the window height without one.
            VStack(alignment: .leading, spacing: SettingsMetrics.sidebarSectionSpacing) {
                ForEach(SettingsTab.sectionOrder(includingDebug: isDebugSectionRevealed), id: \.self) { section in
                    sectionGroup(section)
                }
            }
            .padding(.leading, SettingsMetrics.sidebarContentLeadingInset)
            .padding(.trailing, SettingsMetrics.sidebarContentTrailingInset)

            Spacer(minLength: 0)

            sessionLockIndicator
                .padding(.leading, SettingsMetrics.sidebarContentLeadingInset)
                .padding(.trailing, SettingsMetrics.sidebarContentTrailingInset)
                .padding(.bottom, 12)
        }
        .frame(width: SettingsMetrics.sidebarWidth)
        .onAppear { pocController.refreshCredentialStatus() }
        // Some unlock paths (Face Lab's debug "Unlock" button, the
        // onboarding flows) call SecureCredentialManager directly rather
        // than through this pocController, so this doesn't just update
        // reactively on its own the way a page reading the same
        // @Observable instance would. Same refresh every gated page already
        // does after the notch closes, so this box stays correct regardless
        // of which page happens to be selected when that happens.
        .onChange(of: NotchOverlayController.shared.phase) { _, newPhase in
            guard newPhase == .closed else { return }
            pocController.refreshCredentialStatus()
        }
    }

    /// Docked to the sidebar's bottom edge, outside the scrolling tab list —
    /// always visible regardless of selection. Doubles as the session's
    /// on/off switch: unlocks while locked, locks while unlocked.
    private var sessionLockIndicator: some View {
        Button(action: toggleSession) {
            HStack(spacing: 8) {
                Image(systemName: pocController.isSessionUnlocked ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsMetrics.textPrimary)
                    .frame(width: 16)
                    // Apple's own textbook case for `.replace` — a padlock
                    // shackle popping open — so this animates the icon
                    // itself rather than a plain crossfade wherever the
                    // system supports it; SwiftUI falls back to a crossfade
                    // on its own if it can't.
                    .contentTransition(.symbolEffect(.replace))
                    // .padding(.leading, 3)

                Text(sessionLockLabel)
                    .font(SettingsMetrics.sidebarItemFont)
                    .foregroundStyle(SettingsMetrics.textPrimary)
                    .contentTransition(.opacity)

                Spacer(minLength: 0)
            }
            .padding(.horizontal,12)
            .frame(maxWidth: .infinity, minHeight: SettingsMetrics.sidebarItemHeight, alignment: .leading)
            .background(SettingsMetrics.rowColor)
            .overlay(
                RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius)
                    .strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
            )
            .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius))
            .contentShape(RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius))
        }
        .buttonStyle(.plain)
        // Only disabled mid-authentication — a tap then would either double
        // up the Touch ID prompt or race the lock it hasn't resolved yet.
        // Otherwise always tappable in both directions.
        .disabled(isUnlocking)
        .animation(SettingsMetrics.stateTransitionAnimation, value: pocController.isSessionUnlocked)
        .animation(SettingsMetrics.stateTransitionAnimation, value: isUnlocking)
    }

    private var sessionLockLabel: String {
        if pocController.isSessionUnlocked { return "Session unlocked" }
        return isUnlocking ? "Authenticating…" : "Session locked"
    }

    private func toggleSession() {
        if pocController.isSessionUnlocked {
            pocController.lockSession()
            return
        }
        isUnlocking = true
        Task {
            await pocController.unlockSession()
            isUnlocking = false
        }
    }

    @ViewBuilder
    private func sectionGroup(_ section: SettingsSection?) -> some View {
        let tabs = SettingsTab.tabs(in: section)
        if !tabs.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                if let section {
                    Text(section.rawValue)
                        .font(SettingsMetrics.sectionHeaderFont)
                        .foregroundStyle(SettingsMetrics.textTertiary)
                        .padding(.horizontal, 10)
                        .padding(.top, 14)
                        .padding(.bottom, 4)
                }
                ForEach(tabs) { tab in
                    sidebarRow(tab)
                }
            }
        }
    }

    private func sidebarRow(_ tab: SettingsTab) -> some View {
        Button {
            selection = tab
        } label: {
            HStack(spacing: 8) {
                SettingsTabIconBadge(
                    icon: tab.icon,
                    gradientColors: tab.badgeGradientColors,
                    size: SettingsMetrics.sidebarIconBadgeSize,
                    cornerRadius: SettingsMetrics.sidebarIconBadgeCornerRadius,
                    iconSize: SettingsMetrics.sidebarIconBadgeGlyphSize
                )
                Text(tab.title)
                    .font(SettingsMetrics.sidebarItemFont)
                    .foregroundStyle(SettingsMetrics.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: SettingsMetrics.sidebarItemHeight, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: SettingsMetrics.selectedPillRadius)
                    .fill(selection == tab ? SettingsMetrics.selectedPillColor : .clear)
            )
            // Without this, the button's hit-testable area shrinks to just
            // the rendered icon+text — not the full row, including the
            // Spacer-filled trailing space — so only tapping directly on
            // the text registered.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
