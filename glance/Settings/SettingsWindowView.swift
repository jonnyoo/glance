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
/// identity (a fresh `id` per instance) rather than by comparing the
/// closures themselves, so this is deliberately never equal to a previous
/// instance: `onPreferenceChange` firing on every render of the publishing
/// page is negligible for a settings header, and correctness (never
/// missing a real change) matters more here than dodging a few redundant
/// reassignments.
struct HeaderAction: Equatable {
    private let id = UUID()
    let perform: () -> Void

    static func == (lhs: HeaderAction, rhs: HeaderAction) -> Bool { lhs.id == rhs.id }
}

/// Lets one page (today, only Camera's "Refresh camera list") publish a
/// trailing action into the shared page header, without the header itself
/// needing to know that page's state. Only the currently-selected page is
/// ever in the view tree, so switching away automatically resolves this
/// back to `defaultValue` — no manual reset needed.
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

    var body: some View {
        ZStack {
            VisualEffectView()
            SettingsMetrics.sidebarBackgroundColor

            HStack(spacing: 0) {
                SettingsSidebar(selection: $selection, pocController: environment.pocController)

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
                    // All four corners now, not just the leading two — the
                    // panel is a floating card inset from every window edge
                    // (see .padding below), not flush against the trailing/
                    // top/bottom edges the way it used to be, so there's no
                    // reason left for the trailing corners to stay square.
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
        // No `.clipShape` on the outer window — deliberately, and this is
        // the fix for the too-square corners. Rounding the content ourselves
        // can only ever *subtract* from the window's real shape, so a
        // hand-picked radius silently overrode the system's; now that the
        // window keeps its native background (see WindowConfiguringView),
        // AppKit masks the whole thing to the genuine macOS 26 corner —
        // measured identical to Finder's, and free to track future OS
        // changes without a constant here to go stale.
        //
        // No manual stroke on the outer window either — macOS already draws its
        // own glass-style edge highlight on a translucent window; a second
        // hand-drawn stroke on top of that just looked doubled.
        //
        // No SwiftUI `.shadow` here either — it would be clipped at the
        // window's edge. The window's own AppKit shadow follows this rounded
        // shape, since the window is transparent (see WindowConfiguringView).
        //
        // Fills whatever size the window is (set once by
        // WindowConfiguringView) rather than declaring a fixed size here —
        // a fixed size combined with content-size resizability is what made
        // SwiftUI keep re-adding a titlebar band to the window height.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .background(WindowConfigurator())
        // Cascades to every native control (Toggle, Slider, Picker, Button)
        // so nothing falls back to the system accent — everything uses the
        // same #347DFF as GlanceTheme. This only takes effect because the
        // window can become key; see WindowConfiguringView.configure.
        .tint(GlanceTheme.accent)
    }

    /// The header floats over the scroll content in a `ZStack` (rather than
    /// sitting above it in a `VStack`) so scrolled rows pass *underneath* it
    /// instead of being pushed down by it. It's fully transparent — see the
    /// note on `SettingsMetrics.headerHeight` for what was tried instead and
    /// why none of it stuck.
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
                AboutSettingsPage()
            case .debugCredentials:
                CredentialPOCView(controller: environment.pocController)
            case .debugFaceLab:
                FaceLabView(controller: environment.faceLabController)
            case .debugFaceUnlock:
                FaceUnlockView(coordinator: environment.faceUnlockCoordinator)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
