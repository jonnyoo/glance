//
//  SettingsSidebar.swift
//  glance
//
//  A fixed, non-collapsible sidebar — plain VStack of buttons rather than
//  NavigationSplitView, whose sidebar can be collapsed by the user.
//

import SwiftUI

struct SettingsSidebar: View {
    @Binding var selection: SettingsTab
    @Bindable var pocController: POCController
    /// Whether the Debug/Face Lab section should render — see
    /// `AppEnvironment.isDebugSectionRevealed`. This view only reflects it.
    let isDebugSectionRevealed: Bool

    @State private var isUnlocking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Empty reserved band — the window's real traffic lights are
            // drawn here by AppKit (see WindowConfiguringView); nothing of
            // ours may sit in this strip.
            Color.clear
                .frame(height: SettingsMetrics.trafficLightBandHeight)

            // Plain VStack, not a ScrollView — the full tab list comfortably
            // fits the window height without scrolling.
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
        // Some unlock paths call SecureCredentialManager directly rather
        // than through this pocController, so this doesn't update
        // reactively on its own — refresh after the notch closes, same as
        // every gated page.
        .onChange(of: NotchOverlayController.shared.phase) { _, newPhase in
            guard newPhase == .closed else { return }
            pocController.refreshCredentialStatus()
        }
    }

    /// Docked to the sidebar's bottom edge, always visible. Doubles as the
    /// session's on/off switch: unlocks while locked, locks while unlocked.
    private var sessionLockIndicator: some View {
        Button(action: toggleSession) {
            HStack(spacing: 8) {
                Image(systemName: pocController.isSessionUnlocked ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(SettingsMetrics.textPrimary)
                    .frame(width: 16)
                    // `.replace` animates the padlock shackle popping open
                    // where supported; SwiftUI falls back to a crossfade.
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
        // Only disabled mid-authentication — a tap then would double up the
        // Touch ID prompt or race the unresolved lock.
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
            // Without this, the hit-testable area shrinks to the rendered
            // icon+text rather than the full row.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
