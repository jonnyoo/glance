//
//  AppLockCurtainController.swift
//  glance
//
//  The cover that goes up over a locked app while its owner is being checked: a blurred panel over each of that app's
//  windows, with the prompt card on top of the frontmost one. Everything else on screen stays visible and usable.
//  Knows nothing about faces or challenges — `AppLockCoordinator` decides when it rises and falls; this only owns the
//  windows.
//
//  Another app's windows aren't ours to attach anything to, so the covers follow them instead: for as long as the
//  curtain is up, the window server is asked many times a second where that app's windows are and how they're stacked.
//  That list carries frames, levels and order without Screen Recording permission — only titles and contents need it.
//

import AppKit
import SwiftUI

// MARK: - Reading the window list

/// One window of the covered app, as the window server reports it.
struct AppLockTargetWindow: Equatable {
    let id: CGWindowID
    /// The window level it sits at.
    let layer: Int
    /// In AppKit screen coordinates.
    let frame: NSRect
}

/// Everything on screen right now, front to back.
struct AppLockWindowSnapshot {
    private struct Entry {
        let id: CGWindowID
        let pid: pid_t
        let layer: Int
        let alpha: Double
        let bounds: CGRect
    }

    private let entries: [Entry]
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// Levels worth covering: ordinary windows, floating panels, dialogs. From the Dock's level up it's menus, menu
    /// bar extras and tooltips — and a locked app's menu bar icon is no more private than its Dock icon.
    private static let coverableLayers = 0..<Int(CGWindowLevelForKey(.dockWindow))
    /// Apps keep stray helper windows a pixel or two across on screen; there's nothing in them to hide.
    private static let minimumEdge: CGFloat = 24

    init() {
        let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        entries = raw.compactMap { info in
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let boundsDictionary = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDictionary) else { return nil }
            let alpha = (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            return Entry(id: id, pid: pid, layer: layer, alpha: alpha, bounds: bounds)
        }
    }

    /// The windows of `pid` that have something to hide, front to back.
    func windows(of pid: pid_t) -> [AppLockTargetWindow] {
        // The window server measures from the top-left of the primary display; AppKit from its bottom-left.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return entries.compactMap { entry in
            guard entry.pid == pid, Self.coverableLayers.contains(entry.layer), entry.alpha > 0,
                  entry.bounds.width >= Self.minimumEdge, entry.bounds.height >= Self.minimumEdge else { return nil }
            let frame = NSRect(
                x: entry.bounds.minX,
                y: primaryHeight - entry.bounds.maxY,
                width: entry.bounds.width,
                height: entry.bounds.height
            )
            return AppLockTargetWindow(id: entry.id, layer: entry.layer, frame: frame)
        }
    }

    /// Whether Mission Control, App Exposé or Show Desktop is on screen. There's no public notification for any of
    /// them; what they share is a screen-sized backdrop that the Dock keeps just below its own level for as long as
    /// they're up. If a future macOS stops doing that this simply never fires, and the covers stay where they are.
    func isShowingWindowOverview(dockPID: pid_t) -> Bool {
        let screenSizes = NSScreen.screens.map(\.frame.size)
        return entries.contains { entry in
            entry.pid == dockPID && entry.layer == Self.overviewBackdropLayer && screenSizes.contains(entry.bounds.size)
        }
    }

    private static let overviewBackdropLayer = Int(CGWindowLevelForKey(.dockWindow)) - 2

    /// Whether `cover` is in front of `target` with nothing between them but that app's own windows and our panels.
    /// Deliberately not "directly in front": a window's children (sheets, attached panels) ride just above it, and a
    /// cover ordered above the parent lands above them too — which is where it should be.
    func isCovered(_ target: CGWindowID, by cover: Int) -> Bool {
        guard let targetIndex = entries.firstIndex(where: { $0.id == target }) else { return true }
        let targetPID = entries[targetIndex].pid
        for entry in entries[..<targetIndex].reversed() {
            if Int(entry.id) == cover { return true }
            guard entry.pid == targetPID || entry.pid == ownPID else { return false }
        }
        return false
    }
}

// MARK: - Panels

/// A blurred, dimmed sheet the exact size of one window of the locked app. It soaks up clicks and scrolling meant for
/// that window and never takes key — typing belongs to the card.
final class AppLockCoverWindow: NSPanel {
    /// A click on the cover is someone trying to use the app; the controller answers by focusing the card.
    var onMouseDown: (() -> Void)?

    private let backdrop = CoverBackdropView()
    private let dim = NSView()

    /// Matches the window underneath, so the cover doesn't poke out past its rounded corners.
    var cornerRadius: CGFloat = -1 {
        didSet {
            guard cornerRadius != oldValue else { return }
            // A layer mask doesn't clip a behind-window blur; `maskImage` is the supported way to shape one.
            backdrop.maskImage = cornerRadius > 0 ? Self.roundedMask(radius: cornerRadius) : nil
            dim.layer?.cornerRadius = cornerRadius
        }
    }

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        // Glance is essentially never the active app while this is up; a panel's default would hide it immediately.
        hidesOnDeactivate = false
        animationBehavior = .none
        // Stays on the Space of the window it covers, and out of the window cycle. `.stationary` rather than
        // `.transient`: when Mission Control starts, a transient panel shrinks and fades by itself, well ahead of the
        // window it's covering, and leaves that window in plain view. A stationary one holds its ground until
        // `AppLockCurtainController` has noticed and the app has been put away.
        collectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .stationary]

        // `.active`, not `.followsWindowActiveState`: this panel is never main, and would otherwise render as a flat
        // inactive grey.
        backdrop.material = .fullScreenUI
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        // The blur alone leaves large shapes and colours readable; this takes them down to an impression.
        dim.wantsLayer = true
        dim.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.5).cgColor
        dim.layer?.cornerCurve = .continuous
        dim.frame = backdrop.bounds
        dim.autoresizingMask = [.width, .height]
        backdrop.addSubview(dim)
        contentView = backdrop
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// AppKit would otherwise nudge the frame clear of the menu bar, leaving the top of a full-screen window exposed.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    override func mouseDown(with event: NSEvent) {
        onMouseDown?()
    }

    /// `nonisolated` so the drawing handler is too: AppKit is free to call it off the main thread.
    private nonisolated static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

/// The cover belongs to an app that isn't active, so without this its first click would be spent on nothing.
private final class CoverBackdropView: NSVisualEffectView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Holds the prompt card. Borderless and non-activating like `NotchWindow`, but it does take key: while it's up,
/// typing must land here rather than in the app underneath, which is still the active app as far as the system is
/// concerned.
final class AppLockCardWindow: NSPanel {
    /// Above any menu or pop-up the covered app could open (`popUpMenu` is 101), so nothing of its can sit on the
    /// card; still far below `NotchWindow`, so the scan animation plays on top of it.
    private static let cardLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.popUpMenuWindow)) + 1)

    init(size: NSSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        // The card draws its own; a window shadow would outline the whole transparent panel.
        hasShadow = false
        isMovable = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        level = Self.cardLevel
        // Every Space and over full-screen apps: a locked app can come forward on any of them. Stationary for the
        // same reason the covers are.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// Centred on a window near the top of the screen, the panel's transparent margin overlaps the menu bar; AppKit
    /// would otherwise push the whole card down to clear it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Buttons on the card have to work on the first click: Glance isn't the active app while it's up.
///
/// Deliberately not generic over the root view: with optimization on, Swift 6.2's inliner crashes on the `deinit` of
/// a generic `NSHostingView` subclass, so a Release build of the generic form doesn't compile at all.
private final class FirstMouseHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Controller

@MainActor
final class AppLockCurtainController {
    /// Builds the SwiftUI root of the card panel. Set once by `AppLockCoordinator` before the first `prepare()`.
    var makeCard: (() -> AnyView)?
    /// Called when Mission Control (or App Exposé, or Show Desktop) opens while the curtain is up. Those lay every
    /// window out in miniature, and a cover can't go along with its window: it's a window of Glance's, not part of
    /// the other app's. All this can do is say so.
    var onWindowOverview: (() -> Void)?

    private var card: AppLockCardWindow?
    /// Covers in use, keyed by the window each one is covering.
    private var covers: [CGWindowID: AppLockCoverWindow] = [:]
    /// Built ahead of time and reused: a locked app's windows are already visible by the time the activation
    /// notification arrives, so covering one has to be an `orderFront` away rather than a window build.
    private var spareCovers: [AppLockCoverWindow] = []

    private var coveredPID: pid_t?
    /// The window the card is centred on. Kept for as long as that window exists, so the card doesn't hop between
    /// windows as they're restacked.
    private var anchorWindow: CGWindowID?
    private var trackingTask: Task<Void, Never>?
    /// Held while the curtain is up. Glance is a background app, and one whose panels all happen to be hidden behind
    /// other windows is fair game for App Nap — which stretches a timer from a frame to seconds.
    private var trackingActivity: NSObjectProtocol?
    private var isRaised = false
    /// Whether the overview was up at the last pass; `nil` until the first pass after a raise. Only its *opening* is
    /// reported: an app brought forward from inside Mission Control (its Dock icon clicked there) arrives while the
    /// overview is still on its way out, and that mustn't count against it.
    private var wasShowingWindowOverview: Bool?
    /// Looked up again if the Dock restarts.
    private var dock: NSRunningApplication?
    /// Bumped on every raise and lower, so a fade-out that's been overtaken by a new raise doesn't order the panels out.
    private var generation = 0

    private let fadeDuration: TimeInterval = 0.22
    /// How often the covers catch up with the windows under them. A window that opens or moves on its own is
    /// uncovered for at most this long.
    private static let trackingInterval: Duration = .milliseconds(33)
    private static let spareCoverCount = 2
    /// macOS's standard window corner. A full-screen window has none.
    private static let windowCornerRadius: CGFloat = 10

    /// Builds the panels without showing them. Cheap to call repeatedly.
    func prepare() {
        if card == nil, let makeCard {
            let panel = AppLockCardWindow(size: AppLockCardMetrics.panelSize)
            let hostingView = FirstMouseHostingView(rootView: makeCard())
            // Sized by the panel, not the other way round: the root is a fixed frame with the card centred in it.
            hostingView.sizingOptions = []
            hostingView.frame = NSRect(origin: .zero, size: AppLockCardMetrics.panelSize)
            hostingView.autoresizingMask = [.width, .height]
            panel.contentView = hostingView
            card = panel
        }
        while spareCovers.count < Self.spareCoverCount {
            spareCovers.append(makeCover())
        }
    }

    /// Covers every window `pid` has on screen and keeps them covered until `lower`.
    func raise(over pid: pid_t) {
        prepare()
        generation &+= 1
        isRaised = true
        wasShowingWindowOverview = nil
        if coveredPID != pid {
            // Still fading out over the previous app.
            releaseCovers()
            anchorWindow = nil
        }
        coveredPID = pid

        // Straight to opaque, cutting off a fade-out that may still be running from the previous challenge.
        let panels = visiblePanels
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            panels.forEach { $0.animator().alphaValue = 1 }
        }
        panels.forEach { $0.alphaValue = 1 }

        sync()
        // Key without activating Glance: keystrokes come here, and the covered app stays frontmost for when it's revealed.
        card?.makeKey()
        startTracking()
    }

    /// `completion` runs once the panels are actually off screen — and not at all if a new raise overtook the fade.
    func lower(animated: Bool, completion: (() -> Void)? = nil) {
        guard isRaised else {
            completion?()
            return
        }
        generation &+= 1
        isRaised = false
        stopTracking()
        guard animated else {
            hidePanels()
            completion?()
            return
        }

        let generation = self.generation
        let panels = visiblePanels
        NSAnimationContext.runAnimationGroup { context in
            context.duration = fadeDuration
            panels.forEach { $0.animator().alphaValue = 0 }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(self?.fadeDuration ?? 0.22))
            guard let self, generation == self.generation else { return }
            self.hidePanels()
            completion?()
        }
    }

    // MARK: - Following the windows

    private func startTracking() {
        if trackingActivity == nil {
            trackingActivity = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Covering a locked app's windows"
            )
        }
        trackingTask?.cancel()
        trackingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.trackingInterval)
                guard let self, !Task.isCancelled, self.isRaised else { return }
                self.sync()
            }
        }
    }

    private func stopTracking() {
        trackingTask?.cancel()
        trackingTask = nil
        if let trackingActivity {
            ProcessInfo.processInfo.endActivity(trackingActivity)
            self.trackingActivity = nil
        }
    }

    /// Brings the covers in line with where the app's windows are right now: one per window, same frame, same level,
    /// stacked just above it.
    private func sync() {
        guard isRaised, let pid = coveredPID else { return }
        let snapshot = AppLockWindowSnapshot()
        let targets = snapshot.windows(of: pid)

        // Closed, minimized, hidden, or on another Space now.
        for id in Array(covers.keys) where !targets.contains(where: { $0.id == id }) {
            guard let cover = covers.removeValue(forKey: id) else { continue }
            cover.orderOut(nil)
            spareCovers.append(cover)
        }

        let screenFrames = NSScreen.screens.map(\.frame)
        for target in targets {
            let cover = covers[target.id] ?? takeCover()
            covers[target.id] = cover

            if cover.frame != target.frame {
                cover.setFrame(target.frame, display: true)
            }
            cover.cornerRadius = screenFrames.contains(target.frame) ? 0 : Self.windowCornerRadius
            // The window's own level and directly above it, rather than a level above everything: another app's
            // window lying over this one stays in front of the cover, exactly as it's in front of the window.
            let level = NSWindow.Level(rawValue: target.layer)
            if cover.level != level {
                cover.level = level
            }
            if !cover.isVisible || !snapshot.isCovered(target.id, by: cover.windowNumber) {
                cover.order(.above, relativeTo: Int(target.id))
            }
        }

        positionCard(over: targets)

        // Last, so whatever the callback sets in motion finds the panels already up to date.
        let isShowingWindowOverview = dockPID.map { snapshot.isShowingWindowOverview(dockPID: $0) } ?? false
        let hasJustOpened = isShowingWindowOverview && wasShowingWindowOverview == false
        wasShowingWindowOverview = isShowingWindowOverview
        if hasJustOpened {
            onWindowOverview?()
        }
    }

    private var dockPID: pid_t? {
        if dock == nil || dock?.isTerminated == true {
            dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        }
        return dock?.processIdentifier
    }

    private func positionCard(over targets: [AppLockTargetWindow]) {
        guard let card else { return }
        let anchor = targets.first { $0.id == anchorWindow } ?? targets.first
        anchorWindow = anchor?.id

        // With no window to sit on — the app came forward with everything closed or minimized — the card stands
        // alone in the middle of the screen the pointer is on.
        let screen: NSScreen?
        let center: NSPoint
        if let anchor {
            center = NSPoint(x: anchor.frame.midX, y: anchor.frame.midY)
            screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
        } else {
            let pointer = NSEvent.mouseLocation
            screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
            center = screen.map { NSPoint(x: $0.visibleFrame.midX, y: $0.visibleFrame.midY) } ?? .zero
        }

        let size = card.frame.size
        // Whole points, or the comparison below would see a difference on every pass and move the panel each time.
        var origin = NSPoint(x: (center.x - size.width / 2).rounded(), y: (center.y - size.height / 2).rounded())
        if let screen {
            // The card itself stays clear of the menu bar and Dock; the panel's transparent margin may overlap them.
            let margin = AppLockCardMetrics.shadowMargin
            let bounds = screen.visibleFrame.insetBy(dx: -margin, dy: -margin)
            origin.x = min(max(origin.x, bounds.minX), max(bounds.minX, bounds.maxX - size.width))
            origin.y = min(max(origin.y, bounds.minY), max(bounds.minY, bounds.maxY - size.height))
        }
        if card.frame.origin != origin {
            card.setFrameOrigin(origin)
        }
        if !card.isVisible {
            card.orderFrontRegardless()
        }
    }

    // MARK: - Panel bookkeeping

    private var visiblePanels: [NSWindow] {
        Array(covers.values) + (card.map { [$0] } ?? [])
    }

    private func makeCover() -> AppLockCoverWindow {
        let cover = AppLockCoverWindow()
        cover.onMouseDown = { [weak self] in self?.card?.makeKey() }
        return cover
    }

    private func takeCover() -> AppLockCoverWindow {
        let cover = spareCovers.popLast() ?? makeCover()
        cover.alphaValue = 1
        return cover
    }

    private func releaseCovers() {
        for cover in covers.values {
            cover.orderOut(nil)
            spareCovers.append(cover)
        }
        covers.removeAll()
    }

    private func hidePanels() {
        releaseCovers()
        card?.orderOut(nil)
        coveredPID = nil
        anchorWindow = nil
    }
}
