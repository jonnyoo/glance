//
//  LoopingVideoView.swift
//  glance
//
//  Plays a bundled video on loop, holding on its last frame for
//  `pauseBetweenLoops` before restarting from the top. Used by the
//  onboarding intro (logo) and pre-setup (idle glyph) screens.
//
//  Distinct from ScanAnimationView: that one plays once and holds forever
//  on a resolved success/failure state; this one loops indefinitely with a
//  timed gap between plays.
//

import SwiftUI
import AVFoundation
import AppKit

struct LoopingVideoView: NSViewRepresentable {
    let resourceName: String
    var pauseBetweenLoops: TimeInterval = 2.0

    func makeNSView(context: Context) -> LoopingVideoHostView {
        let view = LoopingVideoHostView()
        view.configure(resourceName: resourceName, pauseBetweenLoops: pauseBetweenLoops)
        return view
    }

    func updateNSView(_ nsView: LoopingVideoHostView, context: Context) {
        nsView.configure(resourceName: resourceName, pauseBetweenLoops: pauseBetweenLoops)
    }
}

final class LoopingVideoHostView: NSView {
    private var player: AVPlayer?
    private let playerLayer = AVPlayerLayer()
    private var endObserver: NSObjectProtocol?
    private var currentResourceName: String?
    private var pauseBetweenLoops: TimeInterval = 2.0
    private var pendingRestart: DispatchWorkItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        playerLayer.videoGravity = .resizeAspect
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
        CATransaction.commit()
    }

    func configure(resourceName: String, pauseBetweenLoops: TimeInterval) {
        self.pauseBetweenLoops = pauseBetweenLoops
        guard resourceName != currentResourceName else { return }
        currentResourceName = resourceName
        teardown()

        guard let url = Bundle.main.url(forResource: resourceName, withExtension: "mp4") else {
            assertionFailure("\(resourceName).mp4 missing from bundle — check glance/Resources/")
            return
        }

        let item = AVPlayerItem(url: url)
        let newPlayer = AVPlayer(playerItem: item)
        newPlayer.isMuted = true
        newPlayer.actionAtItemEnd = .pause

        playerLayer.player = newPlayer
        player = newPlayer

        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: item,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleRestart()
        }

        newPlayer.seek(to: .zero)
        newPlayer.play()
    }

    private func scheduleRestart() {
        pendingRestart?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, let player = self.player else { return }
            player.seek(to: .zero)
            player.play()
        }
        pendingRestart = work
        DispatchQueue.main.asyncAfter(deadline: .now() + pauseBetweenLoops, execute: work)
    }

    private func teardown() {
        pendingRestart?.cancel()
        pendingRestart = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        player?.pause()
        player = nil
        playerLayer.player = nil
    }
}
