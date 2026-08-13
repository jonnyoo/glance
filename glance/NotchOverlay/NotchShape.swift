//
//  NotchShape.swift
//  glance
//
//  The notch silhouette. The defining detail is the *inverted* top corners:
//  they curve outward (concave) so the panel flares into the surrounding
//  menu bar instead of reading as a floating rounded card — the same
//  geometry the physical MacBook notch has.
//
//  Path structure follows the well-established notch path from
//  DynamicNotchKit (MIT), which the Boring Notch reference also builds on.
//  The flare has no standard-shape equivalent (it's a concave "anti-corner",
//  not a rounded one), so it stays a hand-built quad curve. The two BOTTOM
//  corners, though, are ordinary convex corners — those are built from
//  Apple's real `.continuous` corner curve (see `ContinuousCorner` below)
//  rather than an approximation, so they're pixel-identical to system UI
//  (Dynamic Island, app icons) instead of a plain circular/quadratic corner.
//
//  Note the body of the notch is inset horizontally by `topRadius` on each
//  side — the flare occupies that margin. `NotchGeometry.flareAllowance`
//  accounts for it so a requested body width lands exactly on the physical
//  notch width.
//
//  In `.pill` style none of that applies: the shape is `UnevenRoundedRectangle`
//  with `.continuous` style, filling the whole rect (a capsule when the radii
//  reach half its height), because it floats free of the screen edge — no
//  flare to build around, so it can use the system shape directly rather
//  than going through `ContinuousCorner`'s splicing.
//
//  `style` is fixed for the lifetime of a given screen and so is
//  deliberately *not* part of `animatableData` — only the radii interpolate,
//  which is what carries the capsule → rounded-rectangle transition.
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
            // Left edge down to where the corner's curvature actually
            // begins (not simply `rect.maxY - bottom` — continuous corners
            // reach further up the straight edge than a circular corner of
            // the same radius would), then the spliced curve into the
            // bottom edge.
            path.addLine(to: corners.leftEdgeReach)
            for segment in corners.left {
                path.addCurve(to: segment.to, control1: segment.control1, control2: segment.control2)
            }
            // Straight run along the bottom edge between the two corners,
            // then the spliced curve up into the right edge.
            path.addLine(to: corners.bottomEdgeRightReach)
            for segment in corners.right {
                path.addCurve(to: segment.to, control1: segment.control1, control2: segment.control2)
            }
            path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        } else {
            // Fallback (should only trigger if a future OS version changes
            // how UnevenRoundedRectangle emits its path elements): the
            // original quad-curve approximation.
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

    /// Ordinary rounded rectangle filling the whole rect, with Apple's real
    /// `.continuous` corner style — this is what makes it read as a genuine
    /// Dynamic Island rather than a plain rounded card.
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

/// Extracts one bottom corner's worth of Apple's real `.continuous` corner
/// curve from a freshly-built `UnevenRoundedRectangle`, so `NotchShape`'s
/// convex bottom corners are pixel-identical to system UI instead of a
/// hand-approximated curve — there's no public API for "just the geometry of
/// one continuous corner," so this builds a reference rounded rect with only
/// the two corners we want (the other two pinned to 0, i.e. sharp) and reads
/// its emitted path elements back out. Recomputed on every call (not
/// memoized), so it stays exact through animated radius changes.
private enum ContinuousCorner {
    struct Segment {
        let control1: CGPoint
        let control2: CGPoint
        let to: CGPoint
    }

    struct BottomCorners {
        /// Point on the left edge where the straight run ends and the
        /// bottom-left corner's curvature begins.
        let leftEdgeReach: CGPoint
        /// Bottom-left corner, left edge → bottom edge (3 segments).
        let left: [Segment]
        /// Point on the bottom edge where the straight run between the two
        /// corners ends and the bottom-right corner's curvature begins.
        let bottomEdgeRightReach: CGPoint
        /// Bottom-right corner, bottom edge → right edge (3 segments). The
        /// last segment's `to` is the point on the right edge where this
        /// corner ends and the straight run back up to the flare begins —
        /// no separate field needed for it, the caller's `addLine` after
        /// the loop just continues from wherever the path already is.
        let right: [Segment]
    }

    /// `bodyRect` is the notch's inset-by-flare body (not the full notch
    /// rect) — using the same rect the caller draws into means the
    /// extracted points already land exactly on our own edges, no
    /// translation needed. Returns `nil` if the reference path doesn't have
    /// the expected shape (see the `notchPath` fallback), which would only
    /// happen if a future OS version changes how the corner is emitted.
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

        // Emitted order (verified empirically — see NotchShape.swift's
        // header): move → line down the right edge (ending at `p1`, where
        // the corner's actual curvature begins — NOT simply
        // `bodyRect.maxY - radius`; continuous corners "reach" further along
        // the straight edge than a circular corner of the same radius would)
        // → 3 curves for the bottom-right corner → line across the bottom →
        // 3 curves for the bottom-left corner → line up the left edge → 6
        // degenerate curves for the (0-radius) top corners → line across the
        // top → close.
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

        // The reference traces right→bottom (p1→p2→p3→p4), straight across
        // the bottom (p4→l5), then bottom→left (l5→p6→p7→p8) — the opposite
        // rotational direction our own path needs (left→bottom, straight,
        // then bottom→right), so everything is reversed: segment order
        // flips within each corner, each segment's own pair of control
        // points swap, and the two corners swap ends.
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
