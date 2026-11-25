//
//  AppLockOverlay.swift
//  glance
//
//  The full-screen blur covering a locked app while its owner proves who they are.
//

import SwiftUI
import AppKit

@Observable
@MainActor
final class AppLockOverlayModel {
    enum Phase: Equatable {
        case scanning
        case notRecognized
        case authenticating
    }

    var appName = ""
    var appIcon: NSImage?
    var phase: Phase = .scanning
    var onTouchID: () -> Void = {}
    var onRetry: () -> Void = {}
    var onCancel: () -> Void = {}
}

/// Borderless but key-capable, so the buttons work and keystrokes can't reach the locked app underneath. Never main, so
/// `AppDelegate`'s Dock-icon bookkeeping (which only counts main-capable windows) ignores it.
private final class AppLockOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class AppLockOverlayController {
    let model = AppLockOverlayModel()
    private var windows: [NSWindow] = []

    /// One window per screen so the locked app can't show through on a second display; only the main screen gets controls.
    func present(appName: String, appIcon: NSImage?) {
        model.appName = appName
        model.appIcon = appIcon
        model.phase = .scanning
        guard windows.isEmpty else { return }

        let controlsScreen = NSScreen.main ?? NSScreen.screens.first
        var keyWindow: NSWindow?
        for screen in NSScreen.screens {
            let showsControls = screen == controlsScreen
            let window = AppLockOverlayWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            // Floating, not screen-saver: the Touch ID / password sheet has to be able to appear above it.
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: AppLockOverlayView(model: model, showsControls: showsControls))
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            windows.append(window)
            if showsControls { keyWindow = window }
        }
        NSApp.activate()
        (keyWindow ?? windows.first)?.makeKey()
    }

    func dismiss() {
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
    }
}

struct AppLockOverlayView: View {
    @Bindable var model: AppLockOverlayModel
    let showsControls: Bool

    var body: some View {
        ZStack {
            VisualEffectView(material: .fullScreenUI, blendingMode: .behindWindow)
            Color.black.opacity(0.35)
            if showsControls {
                controls
            }
        }
        .ignoresSafeArea()
    }

    private var controls: some View {
        VStack(spacing: 18) {
            if let icon = model.appIcon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 84, height: 84)
            }
            Text(String(localized: "\(model.appName) is locked"))
                .font(.system(size: 26, weight: .bold))
                .foregroundStyle(.white)
            Image(systemName: "faceid")
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.white.opacity(0.9))
                .symbolEffect(.pulse, isActive: model.phase == .scanning)
            Text(statusText)
                .font(.system(size: 14))
                .foregroundStyle(.white.opacity(0.75))
            HStack(spacing: 12) {
                PillButton(title: String(localized: "Cancel"), style: .secondary) { model.onCancel() }
                if model.phase == .notRecognized {
                    PillButton(title: String(localized: "Try again"), style: .secondary) { model.onRetry() }
                }
                PillButton(title: String(localized: "Open with Touch ID"), isEnabled: model.phase != .authenticating) {
                    model.onTouchID()
                }
            }
            .padding(.top, 8)
        }
        .padding(40)
        .onExitCommand { model.onCancel() }
    }

    private var statusText: String {
        switch model.phase {
        case .scanning: return String(localized: "Look at the camera to open it")
        case .notRecognized: return String(localized: "Face not recognized")
        case .authenticating: return String(localized: "Authenticating…")
        }
    }
}
