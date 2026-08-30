//
//  OnboardingControls.swift
//  glance
//
//  Shared pill-shaped primitives used across the onboarding step views —
//  lifted directly from the repeated shapes in the Figma frames (buttons,
//  permission rows, the password field) so each step view stays a plain
//  layout description instead of re-deriving this chrome per screen.
//

import SwiftUI
import AppKit

/// The primary (accent-filled) or secondary (dark) pill button used for
/// Next/Back/Confirm across every step.
struct PillButton: View {
    enum Style { case primary, secondary }

    let title: String
    var style: Style = .primary
    var width: CGFloat = OnboardingMetrics.primaryButtonWidth
    var isEnabled = true
    /// Return/Enter activates this button when a focused text field doesn't
    /// consume it — same as a Mac dialog's default button.
    var isDefault = false
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            Text(title)
                .font(GlanceTheme.Font.button)
                .foregroundStyle(GlanceTheme.textPrimary)
                .frame(width: width, height: OnboardingMetrics.pillButtonHeight)
                .background(background)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .disabled(!isEnabled)

        if isDefault {
            button.keyboardShortcut(.defaultAction)
        } else {
            button
        }
    }

    private var background: Color {
        style == .primary ? GlanceTheme.accent : GlanceTheme.surface
    }
}

/// One row on the Permissions screen: status dot, title/detail, and a Grant
/// pill that disables once granted.
struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let grant: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(granted ? GlanceTheme.statusGranted : GlanceTheme.statusDenied)
                .frame(width: OnboardingMetrics.statusDotSize, height: OnboardingMetrics.statusDotSize)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(GlanceTheme.Font.rowTitle)
                    .foregroundStyle(GlanceTheme.textPrimary)
                Text(detail)
                    .font(GlanceTheme.Font.rowDetail)
                    .foregroundStyle(GlanceTheme.textDetail)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
            }

            Spacer(minLength: 4)

            Button(action: grant) {
                Text(granted ? "Granted" : "Grant")
                    .font(GlanceTheme.Font.grantLabel)
                    .foregroundStyle(GlanceTheme.textPrimary)
                    .frame(width: OnboardingMetrics.grantButtonSize.width, height: OnboardingMetrics.grantButtonSize.height)
                    .background(GlanceTheme.surfaceRaised)
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(granted)
            .opacity(granted ? 0.6 : 1)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
        .frame(height: OnboardingMetrics.permissionRowHeight)
        .background(GlanceTheme.surface)
        .clipShape(Capsule())
    }
}

/// The password entry field — a pill-shaped `SecureField` matching the
/// Figma "Enter password..." control.
struct PillSecureField: View {
    let placeholder: String
    @Binding var text: String
    var autofocus = false
    var onSubmit: () -> Void = {}
    @FocusState private var isFocused: Bool

    var body: some View {
        SecureField("", text: $text, prompt: Text(placeholder).foregroundStyle(GlanceTheme.placeholder))
            .textFieldStyle(.plain)
            .font(GlanceTheme.Font.passwordPlaceholder)
            .foregroundStyle(GlanceTheme.textPrimary)
            .focused($isFocused)
            .onSubmit(onSubmit)
            .background(OnboardingFieldFirstResponder(enabled: autofocus, onReady: { isFocused = true }))
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(GlanceTheme.surface)
            .clipShape(Capsule())
    }
}

/// The plain-text twin of `PillSecureField`, used by the naming step. Same
/// capsule so the two read as one control family — only the echo differs.
struct PillTextField: View {
    let placeholder: String
    @Binding var text: String
    var autofocus = false
    var onSubmit: () -> Void = {}
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("", text: $text, prompt: Text(placeholder).foregroundStyle(GlanceTheme.placeholder))
            .textFieldStyle(.plain)
            .font(GlanceTheme.Font.passwordPlaceholder)
            .foregroundStyle(GlanceTheme.textPrimary)
            .focused($isFocused)
            .onSubmit(onSubmit)
            .background(OnboardingFieldFirstResponder(enabled: autofocus, onReady: { isFocused = true }))
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 40)
            .background(GlanceTheme.surface)
            .clipShape(Capsule())
    }
}

/// Makes a notch-hosted field first responder after the step spring
/// finishes. SwiftUI's `.focused` alone is ignored while the panel is
/// still becoming key (and during the step transition), which is why
/// these fields previously required a click. Walking to the real
/// `NSTextField` and calling `makeFirstResponder` is what actually
/// puts the caret in the box.
private struct OnboardingFieldFirstResponder: NSViewRepresentable {
    let enabled: Bool
    let onReady: () -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard enabled, !context.coordinator.didSchedule else { return }
        context.coordinator.didSchedule = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(OnboardingMetrics.fieldAutofocusDelay))
            NSApp.activate(ignoringOtherApps: true)
            for _ in 0..<8 {
                if nsView.window != nil { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let window = nsView.window else { return }
            window.makeKeyAndOrderFront(nil)
            if let field = nearestTextField(from: nsView) {
                window.makeFirstResponder(field)
            }
            onReady()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var didSchedule = false }
}

private func nearestTextField(from view: NSView) -> NSView? {
    var current: NSView? = view.superview
    while let node = current {
        if let field = firstTextField(in: node) { return field }
        current = node.superview
    }
    return nil
}

private func firstTextField(in view: NSView) -> NSView? {
    if view is NSTextField { return view }
    for child in view.subviews {
        if let found = firstTextField(in: child) { return found }
    }
    return nil
}
