//
//  AppLockShieldPanel.swift
//  glance
//
//  A borderless NSPanel subclass for blocking access to locked apps.
//

import AppKit
import SwiftUI

final class AppLockShieldPanel: NSPanel {
    init(screen: NSScreen, model: AppLockShieldModel) {
        let frame = screen.frame
        super.init(contentRect: frame,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        
        self.level = .mainMenu + 2
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = false
        self.hidesOnDeactivate = false
        self.animationBehavior = .none
        
        let hostingView = NSHostingView(rootView: AppLockShieldView(model: model))
        hostingView.frame = self.contentRect(forFrameRect: frame)
        self.contentView = hostingView
    }
    
    override var canBecomeKey: Bool {
        return true
    }
    
    override var canBecomeMain: Bool {
        return false
    }
}
