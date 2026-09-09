//
//  NotchShape.swift
//  glance
//
//  The notch silhouette. Inverted (concave) top corners flare the panel into the
//  menu bar; the flare has no standard-shape equivalent so it's a hand-built quad
//  curve, while the bottom corners use Apple's real `.continuous` curve (see
//  `ContinuousCorner`) for pixel parity with system UI. Body is inset by `topRadius`
//  per side for the flare (see `NotchGeometry.flareAllowance`).
//
//  `style` is fixed per screen, so deliberately excluded from `animatableData` —
//  only the radii interpolate.
//

import SwiftUI

struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat
    var style: NotchPanelStyle = .notch

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
        switch style {
        case .notch: return notchPath(in: rect)
        case .pill: return pillPath(in: rect)
        }
    }

    private func notchPath(in rect: CGRect) -> Path {
        // Clamp so a small closed size can't produce self-intersecting
        // curves when the radii exceed half the available width/height.
        let top = max(0, min(topRadius, rect.width / 2))
        let bottom = max(0, min(bottomRadius, min(rect.width / 2 - top, rect.height)))

        var path = Path()

        // Top-left: flare outward to meet the screen edge.
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top, y: rect.minY + top),
            control: CGPoint(x: rect.minX + top, y: rect.minY)
        )

        if let corners = ContinuousCorner.bottomCorners(
            bodyRect: CGRect(x: rect.minX + top, y: rect.minY, width: rect.width - 2 * top, height: rect.height),
            radius: bottom
        ) {
            // Not simply `rect.maxY - bottom` — continuous corners reach further up
            // the straight edge than a circular corner of the same radius would.
            path.addLine(to: corners.leftEdgeReach)
            for segment in corners.left {
                path.addCurve(to: segment.to, control1: segment.control1, control2: segment.control2)
            }
            path.addLine(to: corners.bottomEdgeRightReach)
            for segment in corners.right {
                path.addCurve(to: segment.to, control1: segment.control1, control2: segment.control2)
            }
            path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        } else {
            // Fallback if a future OS version changes how UnevenRoundedRectangle
            // emits its path: the original quad-curve approximation.
            path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
                control: CGPoint(x: rect.minX + top, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
                control: CGPoint(x: rect.maxX - top, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        }

        // Top-right flare.
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - top, y: rect.minY)
        )

        path.closeSubpath()
        return path
    }

    /// Apple's real `.continuous` corner style — reads as a genuine Dynamic Island
    /// rather than a plain rounded card.
    private func pillPath(in rect: CGRect) -> Path {
        let limit = min(rect.width, rect.height) / 2
        let top = max(0, min(topRadius, limit))
        let bottom = max(0, min(bottomRadius, limit))
        return UnevenRoundedRectangle(
            topLeadingRadius: top,
            bottomLeadingRadius: bottom,
            bottomTrailingRadius: bottom,
            topTrailingRadius: top,
            style: .continuous
        ).path(in: rect)
    }
}

/// There's no public API for "just the geometry of one continuous corner," so this
/// builds a reference rect with only the two corners wanted (others pinned to 0)
/// and reads its emitted path elements back out. Not memoized, so it stays exact
/// through animated radius changes.
private enum ContinuousCorner {
    struct Segment {
        let control1: CGPoint
        let control2: CGPoint
        let to: CGPoint
    }

    struct BottomCorners {
        /// Where the left edge's straight run ends and the corner's curvature begins.
        let leftEdgeReach: CGPoint
        /// Bottom-left corner, left edge → bottom edge (3 segments).
        let left: [Segment]
        /// Where the straight run between the two corners ends and the right corner begins.
        let bottomEdgeRightReach: CGPoint
        /// Bottom-right corner, bottom edge → right edge (3 segments).
        let right: [Segment]
    }

    /// `bodyRect` is the notch's inset-by-flare body, so extracted points already land
    /// on our own edges. Returns `nil` if a future OS version changes how the corner is emitted.
    static func bottomCorners(bodyRect: CGRect, radius: CGFloat) -> BottomCorners? {
        let reference = UnevenRoundedRectangle(
            topLeadingRadius: 0,
            bottomLeadingRadius: radius,
            bottomTrailingRadius: radius,
            topTrailingRadius: 0,
            style: .continuous
        ).path(in: bodyRect)

        var elements: [Path.Element] = []
        reference.forEach { elements.append($0) }

        // Emitted order (verified empirically): move → line down the right edge (to p1,
        // where curvature begins) → 3 curves (bottom-right) → line across the bottom →
        // 3 curves (bottom-left) → line up the left edge → degenerate top-corner curves → close.
        guard elements.count >= 9,
              case .line(let p1) = elements[1],
              case .curve(let p2, let c2a, let c2b) = elements[2],
              case .curve(let p3, let c3a, let c3b) = elements[3],
              case .curve(let p4, let c4a, let c4b) = elements[4],
              case .line(let l5) = elements[5],
              case .curve(let p6, let c6a, let c6b) = elements[6],
              case .curve(let p7, let c7a, let c7b) = elements[7],
              case .curve(let p8, let c8a, let c8b) = elements[8]
        else { return nil }

        // The reference traces right→left; our path needs left→right, so everything
        // is reversed: segment order flips within each corner, control points swap,
        // and the two corners swap ends.
        return BottomCorners(
            leftEdgeReach: p8,
            left: [
                Segment(control1: c8b, control2: c8a, to: p7),
                Segment(control1: c7b, control2: c7a, to: p6),
                Segment(control1: c6b, control2: c6a, to: l5),
            ],
            bottomEdgeRightReach: p4,
            right: [
                Segment(control1: c4b, control2: c4a, to: p3),
                Segment(control1: c3b, control2: c3a, to: p2),
                Segment(control1: c2b, control2: c2a, to: p1),
            ]
        )
    }
}

#Preview("Notch") {
    NotchShape(topRadius: 16, bottomRadius: 65)
        .frame(width: 380, height: 260)
        .padding(20)
}

#Preview("Notch — closed") {
    NotchShape(topRadius: 8, bottomRadius: 12)
        .frame(width: 200, height: 32)
        .padding(20)
}

#Preview("Pill — collapsed") {
    NotchShape(topRadius: 16, bottomRadius: 16, style: .pill)
        .frame(width: NotchGeometry.pillClosedSize.width, height: NotchGeometry.pillClosedSize.height)
        .padding(20)
}

#Preview("Pill — expanded") {
    NotchShape(
        topRadius: NotchGeometry.pillOpenCornerRadius,
        bottomRadius: NotchGeometry.pillOpenCornerRadius,
        style: .pill
    )
    .frame(width: 380, height: 220)
    .padding(20)
}
