//
//  AppLockShieldController.swift
//  glance
//
//  Manages shield panels across all displays.
//

import AppKit
import SwiftUI

@MainActor
final class AppLockShieldController {
    static let shared = AppLockShieldController()
    
    let model = AppLockShieldModel()
    private var panels: [AppLockShieldPanel] = []
    
    private init() {
        // Monitors screen changes to add/remove panels for connected displays
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.updatePanelsForScreens()
        }
    }
    
    func prepare() {
        updatePanelsForScreens()
    }
    
    private func updatePanelsForScreens() {
        let isPresenting = !panels.isEmpty && panels.first?.isVisible == true
        
        // Remove old panels
        for panel in panels {
            panel.orderOut(nil)
        }
        panels.removeAll()
        
        // Create new panels for current screens
        for screen in NSScreen.screens {
            let panel = AppLockShieldPanel(screen: screen, model: model)
            panels.append(panel)
        }
        
        if isPresenting {
            showPanels()
        }
    }
    
    private func showPanels() {
        for panel in panels {
            panel.alphaValue = 1.0
            panel.orderFrontRegardless()
        }
    }
    
    func present(appName: String, icon: NSImage?, pid: pid_t) {
        model.appName = appName
        model.appIcon = icon
        model.state = .verifying
        
        if panels.isEmpty {
            updatePanelsForScreens()
        }
        
        showPanels()
    }
    
    func dismiss() {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.25
            for panel in panels {
                panel.animator().alphaValue = 0.0
            }
        }, completionHandler: {
            for panel in self.panels {
                panel.orderOut(nil)
            }
        })
    }
}
