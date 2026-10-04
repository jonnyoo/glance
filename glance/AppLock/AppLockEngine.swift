//
//  AppLockEngine.swift
//  glance
//
//  The decision core of App Lock: which app is unlocked, which is being challenged, and what has to happen when the
//  frontmost app changes. A plain value type with no AppKit, so `tools/applock_selftest.swift` can drive every transition
//  without launching an app or opening a camera. `AppLockCoordinator` feeds it workspace events and carries out the
//  effects it returns.
//
//  The one invariant everything here protects: a locked app is on screen only while it's unlocked or sitting under the
//  curtain. Relocking, hiding and cancelling are all derived from that.
//

import Foundation

nonisolated struct AppLockEngine {
    /// The slice of `NSRunningApplication` the decisions depend on.
    struct App: Equatable {
        let pid: Int32
        let bundleID: String
        /// Dock-visible, as opposed to an agent or menu bar utility. Only a regular app taking over counts as the user
        /// leaving — system auth dialogs and menu bar tools come forward all the time without that meaning anything.
        let isRegular: Bool
    }

    /// A locked app as `reconcile` sees it: running, and either on screen or not.
    struct RunningApp: Equatable {
        let app: App
        let isHidden: Bool
    }

    enum Phase: Equatable {
        /// The app is frontmost but covered: scanning for a face, or waiting on the user after a failed scan.
        case curtain
        /// The app is hidden and the system's Touch ID / password prompt is up instead.
        case systemPrompt
    }

    struct Challenge: Equatable {
        /// Lets a scan or prompt that finishes late tell it has been superseded.
        let id: Int
        let app: App
        var phase: Phase
    }

    enum Resolution: Equatable {
        /// Authenticated — uncover the app where it stands.
        case unlocked
        /// Given up on — the app has to be out of sight before the curtain goes.
        case cancelled
        /// Nothing left to protect (the app quit, hid itself, or stopped being locked) — just drop the curtain.
        case abandoned
    }

    enum Effect: Equatable {
        case raiseCurtain(Challenge)
        case lowerCurtain(App, Resolution)
        case hide(App)
        case presentSystemPrompt(Challenge)
        case cancelSystemPrompt
        case reopen(App)
    }

    /// A system-prompt success, waiting for the app to come forward. Needed because that path hides the app first and
    /// reopens it afterwards, and the reopen arrives as an ordinary activation that would otherwise be challenged again.
    private struct Grant: Equatable {
        let bundleID: String
        let expires: Date
    }

    /// Long enough to cover a slow reopen — and, if the reopen never lands, for the user's own click to count instead.
    static let grantLifetime: TimeInterval = 15

    private(set) var isEnabled = false
    private(set) var lockedBundleIDs: Set<String> = []
    private(set) var challenge: Challenge?
    /// At most one: unlocking requires being frontmost, and another app taking over relocks it.
    private(set) var unlocked: App?
    private var grant: Grant?
    private var lastChallengeID = 0

    func isLocked(_ app: App) -> Bool {
        lockedBundleIDs.contains(app.bundleID)
    }

    // MARK: - Configuration

    /// Called whenever the toggle or the list changes. Anything that just stopped being locked is released on the spot
    /// rather than left hidden or under a curtain nobody can justify any more.
    mutating func configure(isEnabled: Bool, lockedBundleIDs: Set<String>) -> [Effect] {
        self.isEnabled = isEnabled
        self.lockedBundleIDs = isEnabled ? lockedBundleIDs : []

        var effects: [Effect] = []
        if let current = challenge, !isLocked(current.app) {
            challenge = nil
            effects.append(current.phase == .curtain ? .lowerCurtain(current.app, .abandoned) : .cancelSystemPrompt)
        }
        if let app = unlocked, !isLocked(app) {
            unlocked = nil
        }
        if let pending = grant, !self.lockedBundleIDs.contains(pending.bundleID) {
            grant = nil
        }
        return effects
    }

    // MARK: - Workspace events

    mutating func appActivated(_ app: App, at now: Date) -> [Effect] {
        guard isEnabled else { return [] }
        var effects: [Effect] = []

        if let current = challenge {
            if current.app.pid == app.pid {
                // Expected under the curtain. Behind the system prompt it means the user brought the app forward again,
                // so it goes back out of sight until the prompt resolves.
                return current.phase == .systemPrompt ? [.hide(app)] : []
            }
            let wantsChallenge = needsChallenge(app, at: now)
            switch current.phase {
            case .curtain:
                guard app.isRegular || wantsChallenge else { return [] }
                challenge = nil
                effects.append(.lowerCurtain(current.app, .cancelled))
            case .systemPrompt:
                // The app the prompt is for is already hidden, so an ordinary switch changes nothing. Another locked
                // app coming forward needs the screen, though.
                if wantsChallenge {
                    challenge = nil
                    effects.append(.cancelSystemPrompt)
                }
            }
        }

        if let previous = unlocked, previous.pid != app.pid, app.isRegular || needsChallenge(app, at: now) {
            unlocked = nil
            effects.append(.hide(previous))
        }

        guard isLocked(app), unlocked?.pid != app.pid else { return effects }
        if redeemGrant(for: app, at: now) {
            unlocked = app
            return effects
        }
        // A system prompt left standing above implies this app held a grant, which has already returned — so this is
        // only belt-and-braces against ever stacking two challenges.
        guard challenge == nil else { return effects }

        lastChallengeID += 1
        let next = Challenge(id: lastChallengeID, app: app, phase: .curtain)
        challenge = next
        effects.append(.raiseCurtain(next))
        return effects
    }

    /// The app went out of sight on its own account (⌘H, or the system hiding it). Hides this engine asked for land
    /// here too, but by then the state they'd touch is already cleared.
    mutating func appHidden(pid: Int32) -> [Effect] {
        if unlocked?.pid == pid {
            unlocked = nil
        }
        guard let current = challenge, current.app.pid == pid, current.phase == .curtain else { return [] }
        challenge = nil
        return [.lowerCurtain(current.app, .abandoned)]
    }

    mutating func appTerminated(pid: Int32) -> [Effect] {
        if unlocked?.pid == pid {
            unlocked = nil
        }
        guard let current = challenge, current.app.pid == pid else { return [] }
        challenge = nil
        return [current.phase == .curtain ? .lowerCurtain(current.app, .abandoned) : .cancelSystemPrompt]
    }

    /// Self-heal against the real world: re-reads the frontmost app as though it had just activated, then puts away every
    /// locked app that's on screen without being unlocked or under the curtain. Run after launches and unhides, which can
    /// show a locked app's windows without ever making it frontmost.
    mutating func reconcile(frontmost: App?, running: [RunningApp], at now: Date) -> [Effect] {
        guard isEnabled else { return [] }
        var effects = frontmost.map { appActivated($0, at: now) } ?? []
        for entry in running where isLocked(entry.app) && !entry.isHidden {
            let app = entry.app
            guard app.pid != frontmost?.pid, app.pid != unlocked?.pid, app.pid != challenge?.app.pid else { continue }
            // Just reopened after a system-prompt success and not frontmost yet: hiding it now would undo the unlock
            // the user has already earned.
            guard !hasGrant(for: app, at: now) else { continue }
            if !effects.contains(.hide(app)) {
                effects.append(.hide(app))
            }
        }
        return effects
    }

    /// Screen lock, sleep, screensaver, or the login session going to the background: nothing stays unlocked across
    /// any of them.
    mutating func lockAll() -> [Effect] {
        var effects: [Effect] = []
        if let current = challenge {
            challenge = nil
            effects.append(current.phase == .curtain ? .lowerCurtain(current.app, .cancelled) : .cancelSystemPrompt)
        }
        if let app = unlocked {
            unlocked = nil
            effects.append(.hide(app))
        }
        grant = nil
        return effects
    }

    // MARK: - Challenge outcomes

    /// A face matched while the curtain was up.
    mutating func passed(challengeID: Int) -> [Effect] {
        guard let current = challenge, current.id == challengeID, current.phase == .curtain else { return [] }
        challenge = nil
        unlocked = current.app
        return [.lowerCurtain(current.app, .unlocked)]
    }

    /// The user asked for Touch ID / password instead.
    mutating func systemPromptRequested(challengeID: Int) -> [Effect] {
        guard var current = challenge, current.id == challengeID, current.phase == .curtain else { return [] }
        current.phase = .systemPrompt
        challenge = current
        return [.presentSystemPrompt(current)]
    }

    mutating func systemPromptFinished(challengeID: Int, success: Bool, at now: Date) -> [Effect] {
        guard let current = challenge, current.id == challengeID, current.phase == .systemPrompt else { return [] }
        challenge = nil
        guard success else { return [] }
        grant = Grant(bundleID: current.app.bundleID, expires: now.addingTimeInterval(Self.grantLifetime))
        return [.reopen(current.app)]
    }

    /// Esc, the Cancel button, or the idle watchdog.
    mutating func cancel(challengeID: Int) -> [Effect] {
        guard let current = challenge, current.id == challengeID, current.phase == .curtain else { return [] }
        challenge = nil
        return [.lowerCurtain(current.app, .cancelled)]
    }

    // MARK: - Grants

    private func hasGrant(for app: App, at now: Date) -> Bool {
        guard let grant else { return false }
        return grant.bundleID == app.bundleID && now < grant.expires
    }

    private func needsChallenge(_ app: App, at now: Date) -> Bool {
        isLocked(app) && unlocked?.pid != app.pid && !hasGrant(for: app, at: now)
    }

    /// Single use, and an expired one is discarded on the way.
    private mutating func redeemGrant(for app: App, at now: Date) -> Bool {
        guard let pending = grant, pending.bundleID == app.bundleID else { return false }
        grant = nil
        return now < pending.expires
    }
}
