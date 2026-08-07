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
                ForEach(SettingsTab.sectionOrder, id: \.self) { section in
                    sectionGroup(section)
                }
            }
            .padding(.horizontal, 12)

            Spacer(minLength: 0)
        }
        .frame(width: SettingsMetrics.sidebarWidth)
    }

    @ViewBuilder
    private func sectionGroup(_ section: SettingsSection?) -> some View {
        let tabs = SettingsTab.tabs(in: section)
        if !tabs.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                if let section {
                    Text(section.rawValue)
                        .font(SettingsMetrics.sectionHeaderFont)
                        .foregroundStyle(SettingsMetrics.textSecondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 6)
                        .padding(.bottom, 2)
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
                Image(systemName: tab.icon)
                    .font(.system(size: 11))
                    .foregroundStyle(SettingsMetrics.textPrimary)
                    .frame(width: 16)
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
