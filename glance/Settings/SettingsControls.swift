//
//  SettingsControls.swift
//  glance
//
//  Reusable pieces for the Settings window: a pill-shaped setting row (the
//  Figma design's repeated row chrome), a custom toggle matching its exact
//  track/knob sizing (SwiftUI's stock `Toggle` can't match that), a slider
//  row, an action-button row, the background blur, and the NSWindow chrome
//  configurator (non-resizable, greyed-out miniaturize/zoom).
//

import SwiftUI
import AppKit
import CoreImage


/// What a tab's icon actually is — a built-in SF Symbol, or a template
/// image from the asset catalog for marks SF Symbols has no equivalent for
/// (e.g. "Your Face"'s custom glyph, `Assets.xcassets/YourFaceIcon`). Lets
/// `SettingsTabIconBadge` render either without the call site caring which.
enum SettingsTabIcon {
    case system(String)
    case asset(String)
}

/// The colored rounded-squircle tile behind a tab's glyph — the same
/// per-category icon treatment macOS System Settings uses (Wi-Fi blue,
/// Battery green, and so on). Used at two sizes from two call sites —
/// `SettingsSidebar`'s row and `SettingsWindowView`'s page header — which is
/// why size/cornerRadius/iconSize are explicit parameters rather than a
/// single hardcoded shape.
///
/// Every tab renders as a flat accent fill today (see
/// `SettingsTab.badgeGradientColors`); this view only draws whatever
/// gradient it's given — that's the one property to touch to give a tab
/// its own two-tone look.
struct SettingsTabIconBadge: View {
    let icon: SettingsTabIcon
    /// Read top-to-bottom — `[topColor, bottomColor]`. A flat tile is just
    /// the same color listed twice; there's no separate flat-fill path to
    /// keep in sync with the gradient one. For a gradient with uneven stop
    /// spacing (more than two colors, or stops not evenly split), add a
    /// `stops: [Gradient.Stop]?` parameter here defaulting to `nil` and, in
    /// `body`, prefer `LinearGradient(gradient: Gradient(stops:), ...)` over
    /// `LinearGradient(colors:, ...)` when it's supplied.
    let gradientColors: [Color]
    let size: CGFloat
    let cornerRadius: CGFloat
    let iconSize: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(LinearGradient(colors: gradientColors, startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(glyph)
            // Same two-ring treatment as `SettingsOptionTile`'s preview
            // tiles: a light-grey hairline on the badge's own edge, plus a
            // second, dark-mode-only black ring just outside it. Reuses
            // those exact tokens rather than new ones so every colored tile
            // in Settings — option previews and tab badges alike — reads as
            // the same kind of object.
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
            // The asset catalog entry (Assets.xcassets/<name>.imageset) is
            // marked `template-rendering-intent: template`, so AppKit fills
            // it from `.foregroundStyle` using the source art's alpha as a
            // mask — the SVG's own stroke color plays no part in what's
            // drawn here.
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
/// tap — the same pattern as macOS's own inline info buttons (e.g. Control
/// Center's per-item tooltips). Deliberately just a `Button` + `.popover`:
/// AppKit already draws the floating bubble, arrow, and vibrant background
/// for free, so there's no chrome to reinvent here — only the trigger glyph
/// and the text inside it are this view's job. Drop it next to any row's
/// title (see `SettingsRowContent.info`) or standalone anywhere else a
/// setting needs a one-line explanation.
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
        // Arrow on the popover's bottom edge so the bubble sits above the
        // glyph, pointing down at it. AppKit may flip if there's no room.
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
/// arbitrary trailing control. Matches the pill-shaped rows in the Figma
/// design (430x50, radius 17, translucent fill + hairline border).
struct SettingsRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    /// Explanatory text for an inline `SettingsInfoButton` next to the
    /// title — `nil` (the default) renders no icon, so this is opt-in per
    /// row rather than a change every existing call site needs to notice.
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
    /// Explanatory text for an inline `SettingsInfoButton` next to the
    /// title — `nil` (the default) renders no icon.
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

/// The system switch, so it picks up AppKit's own rendering (Liquid Glass
/// on macOS 26) rather than a hand-drawn approximation.
///
/// This only renders correctly because the window is `.titled` and can
/// therefore become key — see `WindowConfiguringView.configure`. In a
/// never-key window AppKit draws this desaturated and ignores `.tint`
/// entirely, which is what previously forced a hand-drawn replacement.
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

/// The un-chromed twin of `SettingsActionRow` — same title/subtitle/button
/// layout, no card background or border of its own — for dropping directly
/// inside a `SettingsGroup` alongside other rows, the same relationship
/// `SettingsRowContent` has to `SettingsRow`.
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

/// The accent pill button both action-row flavors above render — factored
/// out so the two stay pixel-identical rather than two copies of the same
/// styling drifting apart.
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
/// edge, the currently-selected option's label on the trailing edge of that
/// same line, and the slider itself beneath both.
///
/// Sized by its content rather than `SettingsMetrics.rowHeight` (which the
/// single-line `SettingsRowContent` uses) since it needs two stacked lines.
struct SettingsSteppedSliderRowContent: View {
    let title: String
    let valueLabel: String
    /// Index into the option list, not a real quantity — see
    /// `AutoLockInterval.sliderIndex`. Whole-number `step` is also what
    /// makes AppKit draw tick marks at each stop.
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
/// filling with red left-to-right as confirmation of progress.
///
/// Used instead of a confirmation dialog for password removal: the action is
/// irreversible, and a hold makes the commitment continuous and cancellable
/// (release at any point and nothing happens) rather than a single click
/// that's easy to fire by reflex.
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
                        // A plain rectangle, not a capsule: a capsule scaled
                        // to a few points wide renders as a shrunken pill
                        // floating inside the button instead of a growing
                        // edge. The outer clip below re-rounds it.
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
                // Drives the fill purely off press state, so releasing early
                // rewinds it — the animation *is* the progress indicator,
                // there's no separate timer that could drift out of step
                // with the gesture's own `minimumDuration`.
                withAnimation(.linear(duration: isPressing ? holdDuration : 0.18)) {
                    fillProgress = isPressing ? 1 : 0
                }
            }
    }
}

/// Standalone accent-filled button matching `SettingsActionRow`'s trailing
/// button. Used both inside rows (`compact`) and on its own in centered
/// empty/locked states — an explicit button rather than SwiftUI's default,
/// which renders as a bordered accent-*text* control and reads as a
/// different species of control next to `HoldToConfirmButton`'s capsule.
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
/// unlocking" or "nothing set up yet" state. Shared by Password (locked /
/// no-password-stored) and Your Face (locked / not-enrolled) rather than
/// each page keeping its own copy, since all four are the exact same
/// layout differing only in icon, text, and what the button does.
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
/// picker's equivalent of `SettingsRowContent`. Drop this directly inside a
/// `SettingsGroup` (after a `SettingsGroupDivider`) to connect a picker to
/// the row that controls it into one continuous card, or wrap it in
/// `SettingsOptionCard` below for a standalone boxed picker.
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

/// Unlock animation picker — the option-tile row that connects, inside one
/// `SettingsGroup`, to the "Show animation" toggle above it (see
/// `GeneralSettingsPage`). Only the two *visible* styles are offered —
/// `.none` is produced by that toggle instead, which is also what
/// `isEnabled` reflects when it greys the tiles out.
struct UnlockAnimationPicker: View {
    @Binding var selection: UnlockAnimationStyle
    var isEnabled: Bool = true

    /// How long the live preview holds on the success animation before
    /// collapsing — matches Face Lab's own "Preview ✓" button
    /// (`FaceLabView.swift`), the only other place that drives
    /// `NotchOverlayController` one-shot for a demo rather than a real scan.
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

    /// Tapping a tile both picks it (even if it's already the current
    /// selection — there's no reason a re-tap shouldn't also replay the
    /// preview) and plays that style's real animation on the actual notch/
    /// pill, via the same one-shot path Face Lab's preview buttons use.
    /// `styleOverride` is what makes this show *the tapped* style rather
    /// than whatever's currently saved — tapping "Original" while "Minimal"
    /// is selected must preview Original, not silently no-op or show the
    /// wrong one.
    private func selectAndPreview(_ style: UnlockAnimationStyle) {
        selection = style
        NotchOverlayController.shared.present(styleOverride: style)
        Task {
            try? await Task.sleep(for: Self.previewHoldDuration)
            NotchOverlayController.shared.finish(success: true)
        }
    }

    /// Artificial standing for what each style actually looks like — a
    /// black pill (minimal) or a black rounded panel (original), each
    /// showing the real unlock animation's still poster frame, matching
    /// the real notch/pill shapes closely enough to read as "this is what
    /// it'll look like" rather than an abstract swatch.
    @ViewBuilder
    private func preview(for style: UnlockAnimationStyle, isSelected: Bool) -> some View {
        switch style {
        case .minimal:
            // Inset from the tile's own edges on both sides — unlike the
            // real minimal pill (which only widens a hardware notch's
            // existing flanks or floats on an external display), there's no
            // surrounding chrome here to imply "this is a small detached
            // capsule," so the margin has to do that job instead.
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
            // Fills the tile edge-to-edge, no inset — the real original
            // style expands to fill the whole panel, so its preview should
            // read as "the whole shape," not an object floating inside it.
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

/// The unlock animation's still poster frame (`unlockstatic.png` — the same
/// asset `ScanAnimationView` shows at rest before any video starts) as a
/// plain SwiftUI `Image`, for the Animation section's static previews.
/// Deliberately not `ScanAnimationView` itself: that's an `AVPlayer`-backed
/// `NSViewRepresentable` built to *play* the unlock/failure videos, which
/// these previews never do — they only ever want the one still frame.
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

/// Liveness depth picker — the option-tile row that connects, inside one
/// `SettingsGroup`, to the "Liveness checks" toggle above it (see
/// `RecognitionSettingsPage`). Same shape as `UnlockAnimationPicker`:
/// mutually exclusive tiles, greyed out by `isEnabled` when the row above
/// is off.
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

/// Multi-select picker for what arms Face Unlock — the option-tile row that
/// connects, inside one `SettingsGroup`, to the "Enable Face Unlock" toggle
/// above it (see `GeneralSettingsPage`). Unlike the animation picker, tiles
/// toggle rather than replace — but the last remaining selection is sticky:
/// with nothing selected the notch would never appear, leaving no way to
/// trigger or retry an unlock. `isEnabled` greys the tiles out, same as
/// `UnlockAnimationPicker`, when the row above is off.
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
/// `.sidebar`, not `.hudWindow`. HUD material is built for on-screen HUDs
/// (the volume/brightness overlay) — a dark treatment that isn't really
/// appearance-correct for a light-mode panel at all; every pixel of "light"
/// this window showed in light mode used to come from our own
/// `sidebarBackgroundColor`/`contentBackgroundColor` overlays painted on top
/// of it, not from the material itself. `.sidebar` is Apple's own
/// purpose-built material for exactly this element (it's what Finder/Mail/
/// Xcode's sidebars use), and reads as a properly light, neutral glass panel
/// on its own rather than needing our overlay to fake that.
///
/// Both `.sidebar` and `.hudWindow` still desaturate whatever's behind the
/// window heavily, though — measured directly against the real desktop
/// wallpaper (not a synthetic test image), an untouched `.sidebar` blur
/// barely picked up any of a strongly saturated pink/purple/blue gradient
/// (only ~5 units of R-vs-B spread out of 255, i.e. next to flat gray). That
/// isn't specific to our material choice: a reference app's own Settings
/// sidebar, known to have the tint effect this is going for, showed the same
/// resistance — a fully saturated, opaque backdrop placed directly behind
/// its real window barely moved its rendered color either. Some of that
/// crushed saturation has to be added back deliberately, which is what
/// `saturationFilter` does.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    /// `CALayer.filters` (not `.backgroundFilters`, and not
    /// `.compositingFilter`) is the one that actually reaches this view's
    /// rendered content — confirmed empirically, not from documentation, by
    /// comparing all three against a saturated test backdrop and sampling
    /// the composited pixels; `.backgroundFilters` moved saturation by less
    /// than a third as much as the other two. `.filters` was picked over
    /// `.compositingFilter` as the more conventional/supported route for
    /// "post-process this layer's own contents".
    ///
    /// `1.75` for light mode: measured directly against the real desktop
    /// wallpaper (not a synthetic gradient), sampling the same window
    /// position at several `inputSaturation` values. `1.0` (no boost) and
    /// low boosts up to ~1.5 were indistinguishable from flat gray against
    /// this material — the material's own desaturation dominates at that
    /// range. Visible pastel tint (matching the level a reference app's own
    /// tinted sidebar shows) starts becoming clear around `1.75`.
    ///
    /// `2.5` for dark mode — measured completely separately, against the
    /// same reference app's own dark-mode sidebar, and it is *not* simply
    /// "lower than light mode": a sweep of 1.15/1.4/1.6 all read as flat,
    /// unwarmed gray against this darker backdrop (no visible improvement
    /// between them), while 4.0 overshot past the reference into an overtly
    /// saturated rust wash. `2.5` was the value that actually matched —
    /// confirmed by sampling the rendered R/B channel ratio, a proxy for
    /// perceived warmth, against the reference's own sidebar under the same
    /// backdrop: 1.154 here vs. 1.156 there. Higher-than-light-mode is
    /// counterintuitive but consistent with the underlying cause: this is a
    /// visibly darker, muddier region of the same wallpaper, and the
    /// material's desaturation curve isn't symmetric across the tonal range
    /// it's fighting against, let alone across appearances. Re-measure both
    /// values the same empirical way if the backdrop or material changes —
    /// don't infer one from the other by a ratio or formula.
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
        // `.followsWindowActiveState`, *not* `.active`. This is the whole
        // reason a native window stops being see-through the moment you
        // switch apps while ours stayed translucent forever: `.active`
        // pins the material on permanently, so the blur keeps sampling the
        // desktop even when the window is neither key nor main. Following
        // the window's state is what AppKit's own sidebars/toolbars do —
        // vibrancy while frontmost, a flat opaque background behind.
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

/// Swaps between `VisualEffectView`'s light/dark saturation filters live —
/// overriding `viewDidChangeEffectiveAppearance()` is what makes this react
/// to the user actually toggling System Settings' appearance while the
/// window is open, not just whatever appearance was active at launch.
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
/// draw a title bar — rather than a custom-shaped window imitating one.
///
/// This is a deliberate reversal of an earlier approach that faked the
/// chrome: a borderless/transparent window, hand-drawn traffic lights, and
/// a SwiftUI `clipShape` standing in for the window's corners. Every one of
/// those pieces had to be maintained against the OS instead of by it, and
/// each drifted:
///
///  * the hand-picked corner radius couldn't track macOS 26's much rounder
///    (and continuous-curve) window corners, and being a clip it could only
///    ever cut *inside* the real shape, so it silently won;
///  * hand-drawn traffic lights don't grey out with window state, don't
///    respond to the hover glyphs, and aren't in the accessibility tree;
///  * a permanently-`.active` background material never dropped its
///    vibrancy when the app lost focus, so the window stayed see-through
///    while every real window around it had gone opaque.
///
/// Keeping the real window and only suppressing the titlebar's *drawing*
/// gets all of that back from AppKit for free. See the individual comments
/// in `configure` for what each line buys and why removing it regresses.
///
/// Note: no `setFrame`/`setContentSize` on every layout pass — that fought
/// SwiftUI's own resize-to-fit-content pass in a mutual invalidation loop
/// and crashed with an AppKit constraint-pass exception in an earlier
/// version. Size is set exactly once, here, since nothing else can resize
/// a non-resizable window afterward.
final class WindowConfiguringView: NSView {
    private var hasConfigured = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !hasConfigured else { return }
        hasConfigured = true

        // Deferred by one runloop turn on purpose. This method is called
        // from inside `-[NSView _setWindow:]`, part-way through a SwiftUI
        // render pass — mutating the window there (in particular swapping
        // its class for key-window support) corrupts an AppKit-internal
        // unfair lock and hard-crashes in `_NSSetBoolValueAndNotify`.
        // Waiting until the attachment has finished avoids that entirely.
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            Self.configure(window)
        }
    }

    private static func configure(_ window: NSWindow) {
        // `.fullSizeContentView` + transparent titlebar + hidden title is
        // the *supported* way to get "no title bar": the window keeps all of
        // its real titlebar machinery — real traffic lights, native frame,
        // native corner mask, native active/inactive appearance — it just
        // doesn't draw a chrome band across the top, and our content extends
        // up underneath it.
        //
        // `.titled` is also load-bearing beyond appearance: AppKit only lets
        // a window become *key* if it has a title bar or resize bar, and a
        // window that is never key draws every control inside it in the
        // inactive appearance — desaturated, foggy, tint ignored. That's
        // what made the native toggles/sliders render dark monochrome back
        // when this was a `.borderless` window. (Keeping `.borderless` and
        // overriding `canBecomeKey` via a runtime subclass does not work
        // either: SwiftUI already has KVO observers on this window, so KVO
        // has itself isa-swizzled it, and swapping the class out from under
        // that crashes in `_NSSetBoolValueAndNotify`.)
        //
        // `.miniaturizable` is present so the yellow button genuinely works.
        // `.resizable` is deliberately absent, which is also what disables
        // the green button (`isZoomable` becomes false) — natively, rather
        // than by drawing a dead control that only looks disabled.
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden

        // An empty, item-less `NSToolbar` — and this is the single thing
        // that buys the macOS 26 corner radius. Measured, not folklore: with
        // window alpha masks captured via `screencapture -o -l<windowID>`
        // and traced, an otherwise identical window rounds to 17.5pt with no
        // toolbar, 23pt with `.unifiedCompact`, and exactly Finder's radius
        // (0.00px RMSE over the whole corner curve) with `.unified`. Tahoe
        // ties the corner radius to the height of the titlebar band, so the
        // taller unified band is what makes the corner rounder — there is no
        // corner-radius API to set, and hardcoding a radius is precisely the
        // thing that made it wrong before.
        //
        // Nothing of the toolbar is visible: it has no items, no delegate,
        // and the titlebar above is transparent with the content drawn
        // underneath it, so this only reserves the band the traffic lights
        // sit in (SettingsMetrics.trafficLightBandHeight keeps our sidebar
        // clear of it).
        let toolbar = NSToolbar(identifier: "GlanceSettingsToolbar")
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        window.isMovableByWindowBackground = true
        window.hasShadow = true

        // Deliberately NOT `isOpaque = false` / `backgroundColor = .clear`.
        // That pairing is what cost this window its native corners: it makes
        // AppKit stop drawing (and stop masking to) the window's own rounded
        // frame, leaving whatever the SwiftUI content clipped itself to as
        // the only visible shape — which is why the corners were stuck at a
        // hand-picked radius that no longer matches macOS 26's much rounder
        // native one, and why nothing here could ever track a future OS
        // change to it. Left at the AppKit defaults, the system mask applies
        // and the corner is the real thing, exactly like Finder's.
        //
        // Translucency does not need a clear background colour: the
        // `NSVisualEffectView` behind the content blends with what's behind
        // the window on its own (see VisualEffectView), and being a real
        // window background is what lets it go opaque when the app is not
        // frontmost, the way every native window does.

        let target = SettingsMetrics.windowSize
        var frame = window.frame
        frame.origin.y += frame.height - target.height // keep the top edge fixed
        frame.size = NSSize(width: target.width, height: target.height)
        window.setFrame(frame, display: true)

        // Belt-and-suspenders non-resizability: `.resizable` is already
        // absent from styleMask above (AppKit's authoritative capability
        // flag — without it there's no resize cursor and no edge/corner
        // drag-to-resize at all), and pinning min == max additionally
        // forecloses any other path to a size change (e.g. window-manager
        // tiling/snap gestures) from ever having anywhere to go.
        window.minSize = target
        window.maxSize = target

        // `ignoringOtherApps` is required when this window is first created
        // after an `.accessory` stretch (first-run onboarding just ended):
        // there is no click in the activation chain, and a plain
        // `NSApp.activate()` leaves the window in the inactive look — controls
        // desaturated, tint ignored — until the user Cmd-Tabs. Menu-bar opens
        // already call `activate(ignoringOtherApps:)` from AppDelegate; this
        // covers the automatic post-onboarding path, where this configure
        // pass is the first moment the NSWindow actually exists.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

// (No `SettingsWindowReference` any more: it existed only so the hand-drawn
// close button had a window to call `close()` on. The real traffic lights
// are wired up by AppKit.)
