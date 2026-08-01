//
//  SettingsWindowView.swift
//  glance
//
//  Root layout: blurred background, the two-layer translucent tint (base
//  layer for the whole window, a second overlay just for the content panel
//  — see SettingsMetrics), a fixed sidebar, and the selected page.
//

import SwiftUI

struct SettingsWindowView: View {
    let environment: AppEnvironment
    @State private var selection: SettingsTab = .general

    var body: some View {
        ZStack {
            VisualEffectView()
            SettingsMetrics.baseLayerColor

            HStack(spacing: 0) {
                SettingsSidebar(selection: $selection)

                ZStack(alignment: .top) {
                    SettingsMetrics.contentOverlayColor
                    contentPage
                }
                .clipShape(
                    UnevenRoundedRectangle(
                        topLeadingRadius: SettingsMetrics.contentCornerRadius,
                        bottomLeadingRadius: SettingsMetrics.contentCornerRadius,
                        bottomTrailingRadius: 0,
                        topTrailingRadius: 0
                    )
                )
                // A thin stroke on just the content panel's leading edge,
                // matching the window's own automatic glass-style edge
                // highlight — this is the one internal seam (sidebar vs.
                // content) that has no system-drawn line of its own. The
                // path wraps around the panel's rounded corners rather than
                // running straight down (see ContentPanelLeadingEdge).
                .overlay {
                    ContentPanelLeadingEdge(
                        topRadius: SettingsMetrics.contentCornerRadius,
                        bottomRadius: SettingsMetrics.contentCornerRadius
                    )
                    .stroke(Color.white.opacity(0.12), lineWidth: 1)
                }
            }
        }
        // Matches macOS 26's own native window corner radius exactly — both
        // the radius and the *continuous* curve style (see
        // SettingsMetrics.outerCornerRadius) — so this clip aligns with
        // AppKit's own rounding of the real window frame instead of
        // competing with it. A smaller radius here doesn't just look
        // squarer, it wins: the visible corner is the intersection of this
        // clip and the window mask, so under-shooting the system radius
        // silently overrides the native shape.
        .clipShape(
            RoundedRectangle(
                cornerRadius: SettingsMetrics.outerCornerRadius,
                style: .continuous
            )
        )
        // No manual stroke on the outer window — macOS already draws its
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
    /// sitting above it in a `VStack`) specifically so scrolled content
    /// passes *underneath* it — that's what gives `ProgressiveBlurView`
    /// something to blur. A solid-background header stacked above the
    /// scroll view would never have anything behind it to blur.
    private var contentPage: some View {
        ZStack(alignment: .top) {
            ScrollView(.vertical) {
                pageBody
                    .padding(.horizontal, SettingsMetrics.contentHorizontalPadding)
                    .padding(.top, SettingsMetrics.headerHeight + 12)
                    .padding(.bottom, 30)
                    // Without an explicit top alignment the scroll view
                    // centers short pages vertically, leaving a large gap
                    // between the header and the first row.
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }

            ProgressiveBlurView()
                .frame(height: SettingsMetrics.headerHeight + 30)

            header
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: selection.icon)
                .font(.system(size: 16))
                .foregroundStyle(SettingsMetrics.textPrimary)
            Text(selection.title)
                .font(SettingsMetrics.contentTitleFont)
                .foregroundStyle(SettingsMetrics.textPrimary)
            Spacer()
        }
        .padding(.horizontal, SettingsMetrics.contentHorizontalPadding)
        .padding(.top, 20)
        .frame(height: SettingsMetrics.headerHeight, alignment: .leading)
    }

    @ViewBuilder
    private var pageBody: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.rowSpacing) {
            switch selection {
            case .general:
                GeneralSettingsPage(pocController: environment.pocController, coordinator: environment.faceUnlockCoordinator)
            case .yourFace:
                YourFaceSettingsPage(environment: environment)
            case .password:
                PasswordSettingsPage()
            case .camera:
                CameraSettingsPage()
            case .recognition:
                RecognitionSettingsPage(coordinator: environment.faceUnlockCoordinator, faceLabController: environment.faceLabController)
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
