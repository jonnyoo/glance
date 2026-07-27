//
//  ScanAnimationView.swift
//  glance
//
//  Plays one of the Face ID-style scan animations exactly once and holds
//  on its final frame — deliberately not looping, since each video ends on
//  a meaningful resolved state (the success video's own checkmark, or the
//  failure video's end state).
//
//  All assets are 432x432 with a solid black background, so they composite
//  natively against the black notch panel with no alpha channel needed.
//

import SwiftUI
import AVFoundation
import AppKit

/// Which media the overlay is showing. `.idle` is a still image (the first
/// frame of the success video) so the transition into a playing video is
/// seamless.
enum ScanMedia: Equatable {
    case idle
    case success
    case failure

    var videoResourceName: String? {
        switch self {
        case .idle: return nil
        case .success: return "unlockanimation"
        case .failure: return "unsuccessfulunlockanimation"
        }
    }
}

struct ScanAnimationView: NSViewRepresentable {
    let media: ScanMedia

    func makeNSView(context: Context) -> ScanAnimationHostView {
        let view = ScanAnimationHostView()
        view.apply(media: media)
        return view
    }

    func updateNSView(_ nsView: ScanAnimationHostView, context: Context) {
        nsView.apply(media: media)
    }
}

final class ScanAnimationHostView: NSView {
    private var player: AVPlayer?
    private let playerLayer = AVPlayerLayer()
    private let stillImageLayer = CALayer()
    private var currentMedia: ScanMedia?
    private var readyObservation: NSKeyValueObservation?
    private var fallbackRevealWorkItem: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()

        stillImageLayer.contentsGravity = .resizeAspect
        if let still = Self.loadStillFromBundle() {
            stillImageLayer.contents = still
        }
        layer?.addSublayer(stillImageLayer)

        playerLayer.videoGravity = .resizeAspect
        playerLayer.isHidden = true
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        stillImageLayer.frame = bounds
        CATransaction.commit()
    }

    func apply(media: ScanMedia) {
        guard media != currentMedia else { return }
        currentMedia = media
        readyObservation = nil
        fallbackRevealWorkItem?.cancel()

        guard let resource = media.videoResourceName else {
            teardownPlayer()
            playerLayer.isHidden = true
            stillImageLayer.isHidden = false
            return
        }

        guard let url = Bundle.main.url(forResource: resource, withExtension: "mp4") else {
            assertionFailure("\(resource).mp4 missing from bundle — check glance/Resources/")
            return
        }

        teardownPlayer()
        let newPlayer = AVPlayer(url: url)
        // This can play at the lock screen — never make noise.
        newPlayer.isMuted = true
        // `.none` leaves the player paused on its final frame rather than
        // rewinding, which is exactly the "linger on the last frame"
        // behavior each animation's ending depends on.
        newPlayer.actionAtItemEnd = .none

        playerLayer.player = newPlayer
        player = newPlayer

        // The still stays visible (and the player layer stays hidden) until
        // the layer actually has a decoded frame ready to show. Swapping on
        // a fixed delay (the previous approach) raced the real decode time
        // and produced a black-frame flash whenever decoding took longer
        // than the guess. `isReadyForDisplay` is the correct signal for
        // "there is now a frame to show."
        let reveal: () -> Void = { [weak self] in
            guard let self else { return }
            // Without disabling implicit actions, toggling `isHidden`
            // cross-fades both layers over CALayer's default ~0.25s — the
            // still fading out while the video fades in, which is exactly
            // the "video briefly fades in from black" flash. This makes
            // the swap instant and atomic instead.
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.playerLayer.isHidden = false
            self.stillImageLayer.isHidden = true
            CATransaction.commit()
        }
        readyObservation = playerLayer.observe(\.isReadyForDisplay, options: [.new]) { [weak self] _, change in
            guard change.newValue == true else { return }
            DispatchQueue.main.async {
                self?.fallbackRevealWorkItem?.cancel()
                reveal()
                self?.readyObservation = nil
            }
        }
        // Safety net only — if isReadyForDisplay never fires for some
        // reason, don't get stuck on the still forever.
        let fallback = DispatchWorkItem { reveal() }
        fallbackRevealWorkItem = fallback
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: fallback)

        newPlayer.seek(to: .zero)
        newPlayer.play()
    }

    private func teardownPlayer() {
        readyObservation = nil
        fallbackRevealWorkItem?.cancel()
        player?.pause()
        player = nil
        playerLayer.player = nil
    }

    /// The asset lives in Resources/ rather than an asset catalog, so
    /// `NSImage(named:)` won't find it — load by URL instead.
    private static func loadStillFromBundle() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "unlockstatic", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}
