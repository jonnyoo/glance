//
//  SettingsControls.swift
//  glance
//
//  Reusable pieces for the Settings window: a pill-shaped setting row, a
//  custom toggle, a slider row, an action-button row, the background blur,
//  and the NSWindow chrome configurator.
//

import SwiftUI
import AppKit
import CoreImage


/// What a tab's icon actually is — a built-in SF Symbol, or a template
/// image from the asset catalog for marks with no SF Symbol equivalent.
enum SettingsTabIcon {
    case system(String)
    case asset(String)
}

/// The colored rounded-squircle tile behind a tab's glyph — the same
/// per-category icon treatment macOS System Settings uses. Used at two
/// sizes (`SettingsSidebar`'s row and `SettingsWindowView`'s page header),
/// hence the explicit size/cornerRadius/iconSize parameters.
struct SettingsTabIconBadge: View {
    let icon: SettingsTabIcon
    /// Read top-to-bottom — `[topColor, bottomColor]`; a flat tile just lists the same color twice.
    let gradientColors: [Color]
    let size: CGFloat
    let cornerRadius: CGFloat
    let iconSize: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(LinearGradient(colors: gradientColors, startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(glyph)
            // Same two-ring treatment as `SettingsOptionTile`'s preview tiles.
            .overlay(
                RoundedRectangle(
                    cornerRadius: cornerRadius + SettingsMetrics.optionPreviewOuterStrokeWidth,
                    style: .continuous
                )
                .strokeBorder(
                    SettingsMetrics.optionPreviewOuterStroke,
                    lineWidth: SettingsMetrics.optionPreviewOuterStrokeWidth
                )
                .padding(-SettingsMetrics.optionPreviewOuterStrokeWidth)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.optionPreviewBorderWidth)
            )
    }

    @ViewBuilder
    private var glyph: some View {
        switch icon {
        case .system(let name):
            Image(systemName: name)
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(.white)
        case .asset(let name):
            // Marked `template-rendering-intent: template`, so AppKit fills
            // it from `.foregroundStyle` using the source art's alpha as a mask.
            Image(name)
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .foregroundStyle(.white)
                .frame(width: iconSize, height: iconSize)
        }
    }
}

/// Small "i" glyph that reveals a short explanation in a native popover on
/// tap. Drop it next to a row's title (see `SettingsRowContent.info`) or
/// standalone anywhere a setting needs a one-line explanation.
struct SettingsInfoButton: View {
    let text: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(SettingsMetrics.textTertiary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("More information")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(SettingsMetrics.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 220, alignment: .leading)
                .padding(12)
        }
    }
}

/// One settings row: label (+ optional subtitle) on the leading edge,
/// arbitrary trailing control. Pill-shaped, 430x50, radius 17, translucent
/// fill + hairline border.
struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    /// Explanatory text for an inline `SettingsInfoButton`; `nil` renders no icon.
    var info: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        SettingsRowContent(title: title, subtitle: subtitle, info: info, trailing: trailing)
            .background(SettingsMetrics.rowColor)
            .overlay(
                RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius)
                    .strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
            )
            .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius))
    }
}

/// Inner label + trailing control shared by standalone rows and grouped cards.
struct SettingsRowContent<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    /// Explanatory text for an inline `SettingsInfoButton`; `nil` renders no icon.
    var info: String? = nil
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(title)
                        .font(SettingsMetrics.rowFont)
                        .foregroundStyle(SettingsMetrics.textPrimary)
                    if let info {
                        SettingsInfoButton(text: info)
                    }
                }
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(SettingsMetrics.textSecondary)
                }
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
        .frame(height: SettingsMetrics.rowHeight)
    }
}

/// Multiple `SettingsRowContent` rows in one card, separated by hairline
/// dividers that match `rowBorder`.
struct SettingsGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(SettingsMetrics.rowColor)
        .overlay(
            RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius)
                .strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
        )
        .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius))
    }
}

/// Full-bleed hairline between rows inside a `SettingsGroup`.
struct SettingsGroupDivider: View {
    var body: some View {
        Rectangle()
            .fill(SettingsMetrics.rowBorder)
            .frame(height: SettingsMetrics.rowBorderWidth)
    }
}

/// The system switch, so it picks up AppKit's own rendering rather than a
/// hand-drawn approximation. Only renders correctly because the window is
/// `.titled` and can become key — see `WindowConfiguringView.configure`;
/// a never-key window draws this desaturated and ignores `.tint`.
struct GlanceToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("", isOn: $isOn)
            .toggleStyle(.switch)
            .labelsHidden()
            .controlSize(.small)
            .tint(GlanceTheme.accent)
    }
}

/// A row combining a title/subtitle with a slider and its live numeric
/// value — used for the raw threshold controls on the Recognition page.
struct SettingsSlider: View {
    let title: String
    var subtitle: String? = nil
    let value: Binding<Float>
    let range: ClosedRange<Float>
    var format: (Float) -> String = { String(format: "%.2f", $0) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(SettingsMetrics.rowFont)
                        .foregroundStyle(SettingsMetrics.textPrimary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(SettingsMetrics.textSecondary)
                    }
                }
                Spacer()
                Text(format(value.wrappedValue))
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundStyle(SettingsMetrics.textSecondary)
            }
            Slider(
                value: Binding(
                    get: { Double(value.wrappedValue) },
                    set: { value.wrappedValue = Float($0) }
                ),
                in: Double(range.lowerBound)...Double(range.upperBound)
            )
            .tint(GlanceTheme.accent)
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
        .padding(.vertical, 10)
        .background(SettingsMetrics.rowColor)
        .overlay(
            RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius)
                .strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
        )
        .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius))
    }
}

/// A row pairing a title/subtitle with an action button — used for "Redo
/// Face Enrollment", "Change Password", etc.
struct SettingsActionRow: View {
    let title: String
    var subtitle: String? = nil
    let buttonTitle: String
    var isDestructive: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            SettingsActionButton(title: buttonTitle, isDestructive: isDestructive, isEnabled: isEnabled, action: action)
        }
    }
}

/// The un-chromed twin of `SettingsActionRow`, for dropping directly inside
/// a `SettingsGroup` alongside other rows.
struct SettingsActionRowContent: View {
    let title: String
    var subtitle: String? = nil
    let buttonTitle: String
    var isDestructive: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        SettingsRowContent(title: title, subtitle: subtitle) {
            SettingsActionButton(title: buttonTitle, isDestructive: isDestructive, isEnabled: isEnabled, action: action)
        }
    }
}

/// The accent pill button both action-row flavors above render.
private struct SettingsActionButton: View {
    let title: String
    var isDestructive: Bool = false
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(isDestructive ? Color.red.opacity(0.85) : GlanceTheme.accent)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

/// A grouped row whose control is a discrete slider: title on the leading
/// edge, the currently-selected option's label on the trailing edge, and
/// the slider itself beneath both. Sized by its content, not
/// `SettingsMetrics.rowHeight`, since it needs two stacked lines.
struct SettingsSteppedSliderRowContent: View {
    let title: String
    let valueLabel: String
    /// Index into the option list, not a real quantity — see `AutoLockInterval.sliderIndex`.
    @Binding var index: Double
    let stopCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                    .font(SettingsMetrics.rowFont)
                    .foregroundStyle(SettingsMetrics.textPrimary)
                Spacer(minLength: 8)
                Text(valueLabel)
                    .font(SettingsMetrics.rowFont)
                    .foregroundStyle(SettingsMetrics.textSecondary)
            }
            Slider(value: $index, in: 0...Double(max(stopCount - 1, 1)), step: 1)
                .controlSize(.regular)
                .tint(GlanceTheme.accent)
                .padding(.top, 8)
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
        .padding(.vertical, SettingsMetrics.sliderRowVerticalPadding)
    }
}

/// A destructive button that only fires after being held down continuously,
/// filling with red left-to-right as confirmation of progress — used
/// instead of a confirmation dialog so the commitment is cancellable
/// mid-hold rather than a single easy-to-reflex click.
struct HoldToConfirmButton: View {
    let title: String
    var holdDuration: TimeInterval = 3
    let action: () -> Void

    @State private var fillProgress: CGFloat = 0

    var body: some View {
        Text(title)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(SettingsMetrics.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        SettingsMetrics.neutralButtonFill
                        // Plain rectangle, not a capsule — a capsule scaled
                        // down renders as a shrunken pill, not a growing edge.
                        Rectangle()
                            .fill(SettingsMetrics.destructiveFill)
                            .frame(width: proxy.size.width * fillProgress)
                    }
                }
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
            .onLongPressGesture(minimumDuration: holdDuration) {
                action()
            } onPressingChanged: { isPressing in
                // The animation itself is the progress indicator, driven
                // purely off press state — no separate timer to drift out
                // of step with the gesture's `minimumDuration`.
                withAnimation(.linear(duration: isPressing ? holdDuration : 0.18)) {
                    fillProgress = isPressing ? 1 : 0
                }
            }
    }
}

/// Standalone accent-filled button matching `SettingsActionRow`'s trailing
/// button. Used both inside rows (`compact`) and on its own in centered
/// empty/locked states.
struct SettingsPrimaryButton: View {
    let title: String
    var isEnabled: Bool = true
    /// Row-height padding; `false` gives the roomier standalone size.
    var compact: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, compact ? 14 : 16)
                .padding(.vertical, compact ? 6 : 7)
                .background(GlanceTheme.accent)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Centered icon + message + primary button — a settings page's "needs
/// unlocking" or "nothing set up yet" state. Shared by Password and Your
/// Face rather than each page keeping its own copy.
struct SettingsEmptyStateView: View {
    let icon: String
    let message: String
    let buttonTitle: String
    var isButtonEnabled: Bool = true
    var caption: String? = nil
    let action: () -> Void

    var body: some View {
        VStack(spacing: SettingsMetrics.emptyStateSpacing) {
            Image(systemName: icon)
                .font(.system(size: SettingsMetrics.emptyStateIconSize, weight: .regular))
                .foregroundStyle(SettingsMetrics.textTertiary)

            Text(message)
                .font(SettingsMetrics.rowFont)
                .foregroundStyle(SettingsMetrics.textSecondary)

            SettingsPrimaryButton(title: buttonTitle, isEnabled: isButtonEnabled, action: action)

            if let caption {
                SettingsCaption(text: caption)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: SettingsMetrics.emptyStateMinHeight)
    }
}

/// Section caption used above a group of rows on a settings page (distinct
/// from the sidebar's own section headers).
struct SettingsCaption: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(SettingsMetrics.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Left-aligned section title sitting above a settings card.
struct SettingsSectionTitle: View {
    let text: String

    var body: some View {
        Text(text)
            .font(SettingsMetrics.sectionTitleFont)
            .foregroundStyle(SettingsMetrics.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, SettingsMetrics.sectionTitleHorizontalInset)
            .padding(.top, SettingsMetrics.sectionTitleVerticalPadding)
    }
}

/// A row of `SettingsOptionTile`s with no chrome of its own — the option
/// picker's equivalent of `SettingsRowContent`. Drop directly inside a
/// `SettingsGroup`, or wrap in `SettingsOptionCard` for a standalone picker.
struct SettingsOptionRow<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(spacing: SettingsMetrics.optionItemSpacing) {
            content()
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
        .padding(.vertical, SettingsMetrics.optionCardVerticalPadding)
    }
}

/// `SettingsOptionRow` with its own card chrome, for a picker that stands
/// alone rather than connecting to a row above it.
struct SettingsOptionCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        SettingsOptionRow(content: content)
            .background(
                RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius)
                    .fill(SettingsMetrics.rowColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: SettingsMetrics.rowRadius)
                    .strokeBorder(SettingsMetrics.rowBorder, lineWidth: SettingsMetrics.rowBorderWidth)
            )
    }
}

/// One selectable preview tile: artwork on a filled rounded rect, a label
/// beneath, and an accent ring when selected. Selection is just a `Bool`, so
/// this serves single-select and multi-select pickers alike.
struct SettingsOptionTile<Preview: View>: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void
    /// Defaults to the standard swatch height every other option picker
    /// uses; `UnlockAnimationPicker` passes a taller value so its artwork
    /// has real room — see `SettingsMetrics.unlockAnimationPreviewHeight`.
    var previewHeight: CGFloat = SettingsMetrics.optionPreviewHeight
    @ViewBuilder var preview: () -> Preview

    /// Tint for artwork drawn as plain shapes, so tiles that don't supply
    /// their own coloring still read as selected/unselected.
    static func previewTint(isSelected: Bool) -> Color {
        isSelected
            ? SettingsMetrics.textPrimary.opacity(0.55)
            : SettingsMetrics.textSecondary.opacity(0.7)
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                preview()
                    .frame(maxWidth: .infinity)
                    .frame(height: previewHeight)
                    .background {
                        SettingsMetrics.optionPreviewFill
                        if isSelected {
                            GlanceTheme.accent.opacity(SettingsMetrics.optionPreviewSelectedTintOpacity)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.optionPreviewCornerRadius, style: .continuous))
                    // Shadow the filled tile alone — selection stroke is overlaid
                    // after so it never changes shadow weight across options.
                    .compositingGroup()
                    .shadow(
                        color: SettingsMetrics.optionPreviewShadowColor,
                        radius: SettingsMetrics.optionPreviewShadowRadius,
                        x: 0,
                        y: 0
                    )
                    .overlay(
                        // Outer black ring (dark mode only) — sits just outside
                        // the rowBorder stroke.
                        RoundedRectangle(
                            cornerRadius: SettingsMetrics.optionPreviewCornerRadius
                                + SettingsMetrics.optionPreviewOuterStrokeWidth,
                            style: .continuous
                        )
                        .strokeBorder(
                            SettingsMetrics.optionPreviewOuterStroke,
                            lineWidth: SettingsMetrics.optionPreviewOuterStrokeWidth
                        )
                        .padding(-SettingsMetrics.optionPreviewOuterStrokeWidth)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: SettingsMetrics.optionPreviewCornerRadius, style: .continuous)
                            .strokeBorder(
                                SettingsMetrics.rowBorder,
                                lineWidth: SettingsMetrics.optionPreviewBorderWidth
                            )
                    )
                    .overlay {
                        if isSelected {
                            // Accent ring ~4pt outside the tile, in addition to
                            // the always-on rowBorder above.
                            let expansion = SettingsMetrics.optionSelectionOutset
                                + SettingsMetrics.optionSelectionStrokeWidth
                            RoundedRectangle(
                                cornerRadius: SettingsMetrics.optionPreviewCornerRadius + expansion,
                                style: .continuous
                            )
                            .strokeBorder(
                                GlanceTheme.accent,
                                lineWidth: SettingsMetrics.optionSelectionStrokeWidth
                            )
                            .padding(-expansion)
                        }
                    }

                Text(title)
                    .font(SettingsMetrics.optionLabelFont)
                    .foregroundStyle(isSelected ? SettingsMetrics.textPrimary : SettingsMetrics.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Unlock animation picker — connects, inside one `SettingsGroup`, to the
/// "Show animation" toggle above it (see `GeneralSettingsPage`). Only the
/// two visible styles are offered; `.none` is produced by that toggle.
struct UnlockAnimationPicker: View {
    @Binding var selection: UnlockAnimationStyle
    var isEnabled: Bool = true

    /// How long the live preview holds on the success animation before collapsing.
    private static let previewHoldDuration: Duration = .seconds(1.5)

    var body: some View {
        SettingsOptionRow {
            ForEach(UnlockAnimationStyle.selectableCases) { style in
                SettingsOptionTile(
                    title: style.title,
                    isSelected: selection == style,
                    action: { selectAndPreview(style) },
                    previewHeight: SettingsMetrics.unlockAnimationPreviewHeight
                ) {
                    preview(for: style, isSelected: selection == style)
                }
            }
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }

    /// Picks the tile (a re-tap replays the preview too) and plays that
    /// style's real animation on the notch/pill via `styleOverride`, so it
    /// always previews the tapped style rather than whatever's saved.
    private func selectAndPreview(_ style: UnlockAnimationStyle) {
        selection = style
        NotchOverlayController.shared.present(styleOverride: style)
        Task {
            try? await Task.sleep(for: Self.previewHoldDuration)
            NotchOverlayController.shared.finish(success: true)
        }
    }

    /// A black pill (minimal) or rounded panel (original), each showing the
    /// real unlock animation's still frame, matching the real notch/pill
    /// shapes closely enough to read as a preview rather than an abstract swatch.
    @ViewBuilder
    private func preview(for style: UnlockAnimationStyle, isSelected: Bool) -> some View {
        switch style {
        case .minimal:
            // Inset on both sides so the margin implies "small detached
            // capsule" in the absence of the real notch's surrounding chrome.
            HStack(spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer(minLength: 8)
                UnlockStillThumbnail()
                    .frame(width: 24, height: 24)
            }
            .padding(.horizontal, 14)
            .frame(height: 38)
            .background(Color.black, in: Capsule(style: .continuous))
            .padding(.horizontal, 16)
        case .original:
            // Fills the tile edge-to-edge, no inset — matches how the real
            // style expands to fill the whole panel.
            VStack {
            UnlockStillThumbnail()
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            // .padding(4)
            .background(Color.black, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .frame(width: 85, height: 85)
        case .none:
            // Not offered as a tile — `showUnlockAnimation` covers it.
            EmptyView()
        }
    }
}

/// The unlock animation's still poster frame (`unlockstatic.png`) as a
/// plain SwiftUI `Image`. Deliberately not `ScanAnimationView` itself —
/// that's an `AVPlayer`-backed view built to play video, which these
/// static previews never need.
private struct UnlockStillThumbnail: View {
    var body: some View {
        if let url = Bundle.main.url(forResource: "unlockstatic", withExtension: "png"),
           let nsImage = NSImage(contentsOf: url) {
            Image(nsImage: nsImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            Color.clear
        }
    }
}

/// Liveness depth picker — connects, inside one `SettingsGroup`, to the
/// "Liveness checks" toggle above it (see `RecognitionSettingsPage`). Same
/// shape as `UnlockAnimationPicker`.
struct LivenessModePicker: View {
    @Binding var selection: LivenessMode
    var isEnabled: Bool = true

    var body: some View {
        SettingsOptionRow {
            ForEach(LivenessMode.allCases) { mode in
                SettingsOptionTile(
                    title: mode.title,
                    isSelected: selection == mode,
                    action: { selection = mode }
                ) {
                    Image(systemName: iconName(for: mode))
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(SettingsOptionTile<EmptyView>.previewTint(isSelected: selection == mode))
                }
            }
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }

    /// A half-filled shield for Light (it only screens *out* spoofs) versus
    /// a checked one for Heavy (it also demands positive proof of life).
    private func iconName(for mode: LivenessMode) -> String {
        switch mode {
        case .light: return "sun.min.fill"
        case .heavy: return "sun.max.fill"
        }
    }
}

/// Multi-select picker for what arms Face Unlock — connects, inside one
/// `SettingsGroup`, to the "Enable Face Unlock" toggle above it. Tiles
/// toggle rather than replace, but the last remaining selection is sticky:
/// with nothing selected the notch would never appear.
struct UnlockTriggerPicker: View {
    @Binding var selection: Set<UnlockTrigger>
    var isEnabled: Bool = true

    var body: some View {
        SettingsOptionRow {
            ForEach(UnlockTrigger.allCases) { trigger in
                let isSelected = selection.contains(trigger)
                SettingsOptionTile(
                    title: trigger.title,
                    isSelected: isSelected,
                    action: { toggle(trigger, isSelected: isSelected) }
                ) {
                    Image(systemName: trigger.iconName)
                        .font(.system(size: 20, weight: .regular))
                        .foregroundStyle(SettingsOptionTile<EmptyView>.previewTint(isSelected: isSelected))
                }
            }
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }

    private func toggle(_ trigger: UnlockTrigger, isSelected: Bool) {
        guard isSelected else {
            selection.insert(trigger)
            return
        }
        // Deselecting the last one is a no-op rather than an error state.
        guard selection.count > 1 else { return }
        selection.remove(trigger)
    }
}

/// Wraps an `NSVisualEffectView` for the window's background blur.
///
/// `.sidebar`, not `.hudWindow` — Apple's own purpose-built material for
/// this element (Finder/Mail/Xcode sidebars), reading as a properly light,
/// neutral glass panel on its own. Both materials still desaturate heavily
/// against real wallpaper, though, which is what `saturationFilter` restores.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    /// `CALayer.filters` is the property that actually reaches this view's
    /// rendered content (confirmed empirically — `.backgroundFilters` moved
    /// saturation by far less). 1.75/2.5 (light/dark) are the boosts that
    /// empirically matched a reference app's tinted sidebar against real
    /// desktop wallpaper — re-measure if the backdrop or material changes.
    private static let lightSaturationFilter: CIFilter = {
        let filter = CIFilter(name: "CIColorControls")!
        filter.setValue(1.75, forKey: "inputSaturation")
        return filter
    }()

    private static let darkSaturationFilter: CIFilter = {
        let filter = CIFilter(name: "CIColorControls")!
        filter.setValue(1.2, forKey: "inputSaturation")
        return filter
    }()

    func makeNSView(context: Context) -> AppearanceAdaptiveVisualEffectView {
        let view = AppearanceAdaptiveVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        // `.followsWindowActiveState`, not `.active` — `.active` pins the
        // material on permanently, so the window stays translucent even
        // when it's neither key nor main.
        view.state = .followsWindowActiveState
        view.wantsLayer = true
        view.lightFilter = Self.lightSaturationFilter
        view.darkFilter = Self.darkSaturationFilter
        view.applyFilterForCurrentAppearance()
        return view
    }

    func updateNSView(_ nsView: AppearanceAdaptiveVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

/// Swaps between `VisualEffectView`'s light/dark saturation filters live,
/// reacting to the user toggling System Settings' appearance while open.
final class AppearanceAdaptiveVisualEffectView: NSVisualEffectView {
    var lightFilter: CIFilter?
    var darkFilter: CIFilter?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyFilterForCurrentAppearance()
    }

    func applyFilterForCurrentAppearance() {
        let isDark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let filter = isDark ? darkFilter : lightFilter
        layer?.filters = filter.map { [$0] }
    }
}

/// Configures the hosting `NSWindow`'s chrome once it's available: fully
/// borderless (see `WindowConfiguringView` for why), fixed-size, and
/// background-draggable since there's no title bar to grab.
struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> WindowConfiguringView {
        WindowConfiguringView()
    }

    func updateNSView(_ nsView: WindowConfiguringView, context: Context) {}
}

/// Makes the hosting window an ordinary macOS window that simply doesn't
/// draw a title bar.
///
/// Note: no `setFrame`/`setContentSize` on every layout pass — that fights
/// SwiftUI's resize-to-fit-content pass in a mutual invalidation loop and
/// can crash. Size is set exactly once, here.
final class WindowConfiguringView: NSView {
    private var hasConfigured = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !hasConfigured else { return }
        hasConfigured = true

        // Deferred by one runloop turn — mutating the window synchronously
        // here (mid SwiftUI render pass) corrupts an AppKit-internal lock
        // and hard-crashes in `_NSSetBoolValueAndNotify`.
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            Self.configure(window)
        }
    }

    private static func configure(_ window: NSWindow) {
        // `.fullSizeContentView` + transparent titlebar + hidden title keeps
        // real titlebar machinery (traffic lights, native corner mask,
        // active/inactive appearance) without drawing a chrome band.
        //
        // `.titled` is also load-bearing: AppKit only lets a window become
        // key if it has a title bar, and a never-key window draws every
        // control desaturated with tint ignored.
        //
        // `.miniaturizable` makes the yellow button work; `.resizable` is
        // deliberately absent, which natively disables the green button too.
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        // An empty, item-less `NSToolbar` with `.unified` style is what
        // buys the macOS 26 corner radius (measured: 17.5pt with no
        // toolbar vs. Finder's own radius with `.unified`). Nothing of it
        // is visible; it only reserves the band the traffic lights sit in.
        let toolbar = NSToolbar(identifier: "GlanceSettingsToolbar")
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        window.isMovableByWindowBackground = true
        window.hasShadow = true

        // Deliberately NOT `isOpaque = false` / `backgroundColor = .clear` —
        // that pairing stops AppKit from masking to the window's own native
        // rounded frame. Left at defaults, the system mask applies and the
        // corner is the real thing. Translucency still works since the
        // `NSVisualEffectView` behind the content blends on its own.

        let target = SettingsMetrics.windowSize
        var frame = window.frame
        frame.origin.y += frame.height - target.height // keep the top edge fixed
        frame.size = NSSize(width: target.width, height: target.height)
        window.setFrame(frame, display: true)

        // Belt-and-suspenders non-resizability alongside the absent
        // `.resizable` style flag — pinning min == max forecloses other
        // paths to a size change (e.g. window-manager tiling/snap).
        window.minSize = target
        window.maxSize = target

        // `ignoringOtherApps` covers the automatic post-onboarding path
        // (window created after an `.accessory` stretch, no click in the
        // activation chain) — otherwise the window opens in the inactive
        // look until the user Cmd-Tabs.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}
