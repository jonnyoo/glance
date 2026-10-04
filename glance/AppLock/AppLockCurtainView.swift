//
//  AppLockCurtainView.swift
//  glance
//
//  The card that sits on a locked app's covered windows: which app is locked, what Glance is doing about it, and the
//  ways out. The covers themselves are plain AppKit (see `AppLockCoverWindow`); the scan animation still plays in the
//  notch, above all of it.
//

import SwiftUI
import AppKit

/// What the card is saying right now. Owned by `AppLockCoordinator`, which builds a fresh one for every challenge.
struct AppLockPrompt {
    enum Status: Equatable {
        case scanning
        /// A scan ran and didn't recognize anyone — retrying is worth offering.
        case failed(String)
        /// A scan can't run at all right now (session locked, no enrolled face, no camera) — retrying isn't.
        case unavailable(String)
        /// Handing over to the system's Touch ID / password prompt.
        case handingOff
        /// Cancelled; waiting for the app to be out of sight before the curtain drops.
        case closing
    }

    let appName: String
    let appIcon: NSImage
    /// Read once when the curtain goes up, rather than on every render of the card.
    let offersTouchID: Bool
    var status: Status

    var systemPromptTitle: String {
        offersTouchID ? "Use Touch ID or Password" : "Use Password"
    }
}

enum AppLockCardMetrics {
    static let cardWidth: CGFloat = 340
    /// Room around the card for its shadow to fall into; the panel is transparent there.
    static let shadowMargin: CGFloat = 50
    /// Fixed, and tall enough for the card at its tallest (a failed scan adds a button), so the panel never has to
    /// resize under the card as its status changes.
    static let panelSize = NSSize(width: cardWidth + shadowMargin * 2, height: 480)
}

/// Root of the card panel: the card, centred in a fixed transparent frame.
struct AppLockCardView: View {
    let coordinator: AppLockCoordinator

    var body: some View {
        ZStack {
            if let prompt = coordinator.prompt {
                AppLockPromptCard(prompt: prompt, coordinator: coordinator)
            }
        }
        .frame(width: AppLockCardMetrics.panelSize.width, height: AppLockCardMetrics.panelSize.height)
    }
}

private struct AppLockPromptCard: View {
    let prompt: AppLockPrompt
    let coordinator: AppLockCoordinator

    private static let buttonWidth: CGFloat = 230

    var body: some View {
        VStack(spacing: 0) {
            Image(nsImage: prompt.appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: 84, height: 84)
                .overlay(alignment: .bottomTrailing) { lockBadge }
                .padding(.bottom, 16)

            Text("\(prompt.appName) is locked")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(GlanceTheme.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            statusLine
                .padding(.top, 6)
                .padding(.bottom, 20)

            actions
        }
        .padding(.horizontal, 30)
        .padding(.top, 30)
        .padding(.bottom, 22)
        .frame(width: AppLockCardMetrics.cardWidth)
        .background(GlanceTheme.panel, in: RoundedRectangle(cornerRadius: 34, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 34, style: .continuous)
                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
        )
        // Flattened first, or every label and button inside casts its own shadow onto its neighbours.
        .compositingGroup()
        .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
        .animation(.easeInOut(duration: 0.2), value: prompt.status)
    }

    private var lockBadge: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(GlanceTheme.textPrimary)
            .frame(width: 26, height: 26)
            .background(GlanceTheme.surfaceRaised, in: Circle())
            .overlay(Circle().strokeBorder(GlanceTheme.panel, lineWidth: 2))
            .offset(x: 4, y: 4)
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            if prompt.status == .scanning {
                Image(systemName: "faceid")
                    .font(.system(size: 13, weight: .medium))
                    .symbolEffect(.pulse, options: .repeating)
            }
            Text(statusText)
                .font(GlanceTheme.Font.button)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(GlanceTheme.textSecondary)
        // Two lines' worth, so the buttons don't jump as the message changes length.
        .frame(minHeight: 34, alignment: .top)
    }

    private var statusText: String {
        switch prompt.status {
        case .scanning: return "Looking for your face…"
        case .failed(let message), .unavailable(let message): return message
        case .handingOff: return prompt.offersTouchID ? "Waiting for Touch ID or your password…" : "Waiting for your password…"
        case .closing: return "Closing…"
        }
    }

    /// Whether the card is still taking input — false once it's on its way out.
    private var isInteractive: Bool {
        switch prompt.status {
        case .scanning, .failed, .unavailable: return true
        case .handingOff, .closing: return false
        }
    }

    private var isFailed: Bool {
        if case .failed = prompt.status { return true }
        return false
    }

    private var actions: some View {
        VStack(spacing: 8) {
            if isFailed {
                PillButton(title: "Try Again", width: Self.buttonWidth) {
                    coordinator.retry()
                }
            }
            PillButton(
                title: prompt.systemPromptTitle,
                // The accent goes to whichever action is the way forward: retrying if a scan can run, this if it can't.
                style: prompt.status.isUnavailable ? .primary : .secondary,
                width: Self.buttonWidth
            ) {
                coordinator.useSystemPrompt()
            }
            Button(action: coordinator.cancel) {
                Text("Cancel")
                    .font(GlanceTheme.Font.button)
                    .foregroundStyle(GlanceTheme.textSecondary)
                    .frame(width: Self.buttonWidth, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .disabled(!isInteractive)
        .opacity(isInteractive ? 1 : 0.4)
    }
}

private extension AppLockPrompt.Status {
    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }
}
