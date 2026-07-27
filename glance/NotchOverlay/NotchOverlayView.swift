//
//  NotchOverlayView.swift
//  glance
//
//  SwiftUI root hosted inside the fixed-size NotchWindow. Only this view's
//  *content* size animates (between the screen's closed-notch geometry and
//  the open footprint) — the window itself never changes size. Asymmetric
//  springs (slight overshoot opening, critically damped closing) match the
//  feel established while studying Boring Notch's animation.
//
//  Interaction is hover-only (see NotchOverlayController) — hovering both
//  triggers activation (wake/retry) and shows a purely cosmetic size+shadow
//  bump, independent of whether this particular hover did anything.
//

import SwiftUI

struct NotchOverlayView: View {
    let controller: NotchOverlayController

    @State private var isHovering = false

    private var isExpanded: Bool {
        switch controller.phase {
        case .closed, .collapsing: return false
        case .scanning, .success, .failure: return true
        }
    }

    private var topRadius: CGFloat {
        isExpanded ? NotchGeometry.openTopRadius : NotchGeometry.closedTopRadius
    }

    private var bottomRadius: CGFloat {
        isExpanded ? NotchGeometry.openBottomRadius : NotchGeometry.closedBottomRadius
    }

    /// The shape's visible body is inset by `topRadius` per side (the flare
    /// lives in that margin), so the frame is widened to compensate — that
    /// way the closed state lands exactly on the physical notch width
    /// instead of coming up short by the flare. The hover bump adds a
    /// uniform few points on top of whatever size the phase already wants.
    private var currentSize: CGSize {
        let body = isExpanded ? NotchGeometry.openSize : controller.geometry.closedSize
        let bump: CGFloat = isHovering ? 6 : 0
        return CGSize(
            width: body.width + NotchGeometry.flareAllowance(topRadius: topRadius) + bump,
            height: body.height + bump
        )
    }

    private var openCloseAnimation: Animation {
        isExpanded
            ? .spring(response: 0.42, dampingFraction: 0.8)
            : .spring(response: 0.45, dampingFraction: 1.0)
    }

    var body: some View {
        ZStack {
            ScanAnimationView(media: controller.media)
                .padding(.leading, NotchGeometry.contentPaddingLeading)
                .padding(.trailing, NotchGeometry.contentPaddingTrailing)
                .padding(.top, NotchGeometry.contentPaddingTop)
                .padding(.bottom, NotchGeometry.contentPaddingBottom)
                // Content dissolves as the panel shrinks: increasing blur
                // plus a fade, so it melts away rather than being abruptly
                // clipped by the collapsing shape.
                .blur(radius: isExpanded ? 0 : 14)
                .opacity(isExpanded ? 1 : 0)
                .scaleEffect(isExpanded ? 1 : 0.88)
        }
        .frame(width: currentSize.width, height: currentSize.height)
        .background(Color.black)
        .clipShape(NotchShape(topRadius: topRadius, bottomRadius: bottomRadius))
        // Shadow only while expanded — with the window staying on-screen
        // continuously in armed mode, a shadow visible at the *closed* size
        // rendered as a faint dim halo sitting around the real notch even
        // after "dismissing." Radius is fixed rather than growing on hover
        // (only darkness changes) since a larger radius needs more
        // window margin than is reserved and was getting clipped.
        .shadow(color: .black.opacity(isExpanded ? (isHovering ? 0.55 : 0.3) : 0), radius: 9)
        .animation(.easeOut(duration: 0.18), value: isHovering)
        .onHover { hovering in
            isHovering = hovering
            if hovering {
                controller.activate()
            }
        }
        .animation(openCloseAnimation, value: isExpanded)
        .frame(
            width: NotchGeometry.windowSize.width,
            height: NotchGeometry.windowSize.height,
            alignment: .top
        )
    }
}
