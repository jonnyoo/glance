//
//  AnimatedCheckmark.swift
//  glance
//
//  A checkmark that draws itself on with a trim animation, used by both the
//  camera-complete step (large, accent blue) and the final "You're all set"
//  step (small, white). Scales to whatever frame the caller gives it.
//

import SwiftUI

private struct CheckmarkShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        path.move(to: CGPoint(x: w * 0.16, y: h * 0.52))
        path.addLine(to: CGPoint(x: w * 0.40, y: h * 0.78))
        path.addLine(to: CGPoint(x: w * 0.86, y: h * 0.22))
        return path
    }
}

struct AnimatedCheckmark: View {
    var color: Color = GlanceTheme.accent
    var lineWidth: CGFloat = 6

    @State private var progress: CGFloat = 0

    var body: some View {
        CheckmarkShape()
            .trim(from: 0, to: progress)
            .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
            .onAppear {
                withAnimation(.easeOut(duration: OnboardingMetrics.checkmarkDrawDuration)) {
                    progress = 1
                }
            }
    }
}
