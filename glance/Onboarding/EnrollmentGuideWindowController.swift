//
//  EnrollmentGuideWindowController.swift
//  glance
//
//  Owns the full-screen dim + rotating arrow + instruction overlay shown
//  while guided enrollment is running. Deliberately separate from
//  NotchOverlay — the brief calls for the notch to show only the camera
//  preview and tick ring, with the pose guidance living full-screen instead.
//
//  One borderless window per connected screen so every display dims, but
//  only the screen hosting the actual notch panel shows the arrow/text —
//  there's only one thing to point at.
//

import AppKit
import SwiftUI

@MainActor
final class EnrollmentGuideWindowController {
    private var windows: [NSWindow] = []

    func present(for controller: OnboardingController) {
        dismiss()
        let primaryScreen = NotchGeometry.preferredScreen()
        for screen in NSScreen.screens {
            let window = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.ignoresMouseEvents = true
            // One below NotchWindow's `.mainMenu + 3` so the notch panel
            // always reads on top of the dim, with no masking needed.
            window.level = .mainMenu + 2
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            window.contentView = NSHostingView(
                rootView: EnrollmentGuideOverlay(controller: controller, showsArrow: screen == primaryScreen)
            )
            window.setFrame(screen.frame, display: true)
            window.orderFrontRegardless()
            windows.append(window)
        }
    }

    func dismiss() {
        guard !windows.isEmpty else { return }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
    }
}
