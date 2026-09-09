//
//  SettingsWindowView.swift
//  glance
//
//  Root layout: blurred background showing through a translucent sidebar,
//  a content panel floating above it as its own inset, shadowed card (see
//  SettingsMetrics.contentBackgroundColor / sidebarBackgroundColor), a fixed
//  sidebar, and the selected page.
//

import SwiftUI

/// A closure `onPreferenceChange` can actually consume — that API requires
/// `Value: Equatable`, which a bare closure can never be. Equality is by
/// identity (a fresh `id` per instance), so this is deliberately never
/// equal to a previous instance.
struct HeaderAction: Equatable {
    private let id = UUID()
    let perform: () -> Void

    static func == (lhs: HeaderAction, rhs: HeaderAction) -> Bool { lhs.id == rhs.id }
}

/// Lets one page (today, only Camera's "Refresh camera list") publish a
/// trailing action into the shared page header without the header needing
/// to know that page's state. Switching away resolves back to `defaultValue`.
struct HeaderTrailingActionKey: PreferenceKey {
    static var defaultValue: HeaderAction? { nil }
    static func reduce(value: inout HeaderAction?, nextValue: () -> HeaderAction?) {
        value = nextValue() ?? value
    }
}

struct SettingsWindowView: View {
    let environment: AppEnvironment
    @State private var selection: SettingsTab = .general
    @State private var headerTrailingAction: HeaderAction?
    @Environment(\.dismissWindow) private var dismissWindow

    /// Defense-in-depth, not the primary gate: Settings is `.suppressed` at
    /// launch and `AppDelegate.revealSettingsWindow()` refuses to open it
    /// while onboarding is incomplete. A real user should never hit this
    /// branch, only a blank frame before `dismissWindow` closes it.
    var body: some View {
        if GlanceSettings.shared.hasCompletedOnboarding {
            settingsContent
        } else {
            Color.clear
                .onAppear { dismissWindow(id: "settings") }
        }
    }

    private var settingsContent: some View {
        ZStack {
            VisualEffectView()
            SettingsMetrics.sidebarBackgroundColor

            HStack(spacing: 0) {
                SettingsSidebar(
                    selection: $selection,
                    pocController: environment.pocController,
                    isDebugSectionRevealed: environment.isDebugSectionRevealed
                )

                ZStack {
                    // Opaque underlay casts the panel drop shadow. Shadow on
                    // the translucent content stack would follow SettingsRow
                    // alpha instead of the card outline.
                    RoundedRectangle(
                        cornerRadius: SettingsMetrics.contentCornerRadius,
                        style: .continuous
                    )
                    .fill(SettingsMetrics.contentShadowFill)
                    .shadow(
                        color: SettingsMetrics.contentShadowColor,
                        radius: SettingsMetrics.contentShadowRadius
                    )

                    ZStack(alignment: .top) {
                        SettingsMetrics.contentBackgroundColor
                        contentPage
                    }
                    // All four corners — the panel is a floating card inset
                    // from every window edge (see .padding below).
                    .clipShape(
                        RoundedRectangle(cornerRadius: SettingsMetrics.contentCornerRadius, style: .continuous)
                    )
                    // Outer black ring (dark mode only) — same treatment as the
                    // Unlock Animation preview tiles.
                    .overlay(
                        RoundedRectangle(
                            cornerRadius: SettingsMetrics.contentCornerRadius
                                + SettingsMetrics.optionPreviewOuterStrokeWidth,
                            style: .continuous
                        )
                        .strokeBorder(
                            SettingsMetrics.optionPreviewOuterStroke,
                            lineWidth: SettingsMetrics.optionPreviewOuterStrokeWidth
                        )
                        .padding(-SettingsMetrics.optionPreviewOuterStrokeWidth)
                    )
                    // Hairline stroke on the content (not the underlay) so it
                    // draws above the clipped page rather than under it.
                    .overlay(
                        RoundedRectangle(cornerRadius: SettingsMetrics.contentCornerRadius, style: .continuous)
                            .strokeBorder(SettingsMetrics.contentStrokeColor, lineWidth: 1)
                    )
                }
                .padding(SettingsMetrics.contentOuterSpacing)
            }
        }
        // No `.clipShape`, manual stroke, or `.shadow` on the outer window —
        // deliberately: the window keeps its native background (see
        // WindowConfiguringView), so AppKit masks it to the real macOS
        // corner and draws its own edge highlight and shadow for free.
        //
        // Fills whatever size the window is (set once by
        // WindowConfiguringView) — a fixed size here combined with
        // content-size resizability made SwiftUI keep re-adding a titlebar
        // band to the window height.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .background(WindowConfigurator())
        // Cascades to every native control so nothing falls back to the
        // system accent. Only takes effect because the window can become
        // key; see WindowConfiguringView.configure.
        .tint(GlanceTheme.accent)
        // `Window` is a singleton scene — closing it only orders the
        // NSWindow out, keeping `@State` alive, so without this `selection`
        // would remember the last tab instead of resetting to General.
        .onDisappear { selection = .general }
    }

    /// The header floats over the scroll content in a `ZStack` so scrolled
    /// rows pass underneath it rather than being pushed down. Fully
    /// transparent — see the note on `SettingsMetrics.headerHeight`.
    private var contentPage: some View {
        ZStack(alignment: .top) {
            ScrollView(.vertical) {
                pageBody
                    .padding(.horizontal, SettingsMetrics.contentHorizontalPadding)
                    .padding(.top, SettingsMetrics.headerHeight + 8)
                    .padding(.bottom, 30)
                    // Without an explicit top alignment the scroll view
                    // centers short pages vertically, leaving a large gap
                    // between the header and the first row.
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            header
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onPreferenceChange(HeaderTrailingActionKey.self) { headerTrailingAction = $0 }
    }

    private var header: some View {
        HStack(spacing: 8) {
            SettingsTabIconBadge(
                icon: selection.icon,
                gradientColors: selection.badgeGradientColors,
                size: SettingsMetrics.headerIconBadgeSize,
                cornerRadius: SettingsMetrics.headerIconBadgeCornerRadius,
                iconSize: SettingsMetrics.headerIconBadgeGlyphSize
            )
            Text(selection.title)
                .font(SettingsMetrics.contentTitleFont)
                .foregroundStyle(SettingsMetrics.textPrimary)
            Spacer()

            if let headerTrailingAction {
                Button(action: headerTrailingAction.perform) {
                    Image(systemName: "arrow.trianglehead.clockwise.rotate.90")
                        .font(.system(size: 13))
                        .foregroundStyle(SettingsMetrics.textPrimary)
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Refresh camera list")
            }
        }
        .padding(.horizontal, SettingsMetrics.contentHorizontalPadding + 4)
        .padding(.top, 10)
        .frame(height: SettingsMetrics.headerHeight, alignment: .leading)
    }

    @ViewBuilder
    private var pageBody: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            switch selection {
            case .general:
                GeneralSettingsPage(coordinator: environment.faceUnlockCoordinator)
            case .yourFace:
                YourFaceSettingsPage(environment: environment)
            case .password:
                PasswordSettingsPage(pocController: environment.pocController)
            case .camera:
                CameraSettingsPage(pocController: environment.pocController)
            case .recognition:
                RecognitionSettingsPage(
                    coordinator: environment.faceUnlockCoordinator,
                    pocController: environment.pocController
                )
            case .about:
                AboutSettingsPage(updater: environment.updater, environment: environment)
            case .debugFaceLab:
                FaceLabView(controller: environment.faceLabController)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
