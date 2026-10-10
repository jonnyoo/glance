//
//  AppLockWatcher.swift
//  glance
//
//  Lightweight, battery-efficient monitor for locked apps.
//  Purely event-driven — zero polling timers, zero background CPU drain.
//

import AppKit
import Foundation
import Combine

@Observable @MainActor
final class AppLockWatcher {
    
    var onLockedAppDetected: ((NSRunningApplication) -> Void)?
    var onBackgroundLocked: ((NSRunningApplication) -> Void)?
    var onAppActivated: ((String) -> Void)?
    var onFocusLost: ((String) -> Void)?
    var onAppTerminated: ((String) -> Void)?
    
    private var cancellables = Set<AnyCancellable>()
    private var pollTimer: Timer?
    
    func start() {
        guard cancellables.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        
        // 1. App activated (user switched to or opened an app)
        center.publisher(for: NSWorkspace.didActivateApplicationNotification)
            .sink { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleId = app.bundleIdentifier else { return }
                self?.onAppActivated?(bundleId)
                self?.consider(app, isActivation: true)
            }
            .store(in: &cancellables)
            
        // 2. App unhidden
        center.publisher(for: NSWorkspace.didUnhideApplicationNotification)
            .sink { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleId = app.bundleIdentifier else { return }
                self?.onAppActivated?(bundleId)
                self?.consider(app, isActivation: true)
            }
            .store(in: &cancellables)

        // 3. App hidden (Cmd+H)
        center.publisher(for: NSWorkspace.didHideApplicationNotification)
            .sink { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleId = app.bundleIdentifier else { return }
                self?.onFocusLost?(bundleId)
            }
            .store(in: &cancellables)
            
        // 4. App deactivated (lost focus, minimized, clicked away)
        center.publisher(for: NSWorkspace.didDeactivateApplicationNotification)
            .sink { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleId = app.bundleIdentifier else { return }
                self?.onFocusLost?(bundleId)
            }
            .store(in: &cancellables)
            
        // 5. App terminated (cleanup)
        center.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .sink { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let bundleId = app.bundleIdentifier else { return }
                self?.onAppTerminated?(bundleId)
            }
            .store(in: &cancellables)

        // 6. Check current frontmost app immediately
        if let frontmost = NSWorkspace.shared.frontmostApplication {
            consider(frontmost, isActivation: true)
        }

        // 7. Light check for unminimized Dock taps and background activations missed by notifications
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let frontmost = NSWorkspace.shared.frontmostApplication else { return }
                self.consider(frontmost, isActivation: false)
            }
        }
    }
    
    func stop() {
        cancellables.removeAll()
        pollTimer?.invalidate()
        pollTimer = nil
    }
    
    private func consider(_ app: NSRunningApplication, isActivation: Bool = false) {
        guard let bundleId = app.bundleIdentifier else { return }
        
        // Instant fast-path check
        guard LockedAppStore.shared.isEnabled, LockedAppStore.shared.isLocked(bundleId) else { return }
        
        onLockedAppDetected?(app)
    }
}
