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
//
//  Note the body of the notch is inset horizontally by `topRadius` on each
//  side — the flare occupies that margin. `NotchGeometry.flareAllowance`
//  accounts for it so a requested body width lands exactly on the physical
//  notch width.
//

import SwiftUI

struct NotchShape: Shape {
    var topRadius: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(topRadius, bottomRadius) }
        set {
            topRadius = newValue.first
            bottomRadius = newValue.second
        }
    }

    func path(in rect: CGRect) -> Path {
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

        // Left side down to the bottom-left corner.
        path.addLine(to: CGPoint(x: rect.minX + top, y: rect.maxY - bottom))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + top + bottom, y: rect.maxY),
            control: CGPoint(x: rect.minX + top, y: rect.maxY)
        )

        // Bottom edge.
        path.addLine(to: CGPoint(x: rect.maxX - top - bottom, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - top, y: rect.maxY - bottom),
            control: CGPoint(x: rect.maxX - top, y: rect.maxY)
        )

        // Right side up to the top-right flare.
        path.addLine(to: CGPoint(x: rect.maxX - top, y: rect.minY + top))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY),
            control: CGPoint(x: rect.maxX - top, y: rect.minY)
        )

        path.closeSubpath()
        return path
    }
}

#Preview {
    NotchShape(topRadius: 10, bottomRadius: 28)
        .frame(width: 280, height: 220)
        .padding(20)
}
