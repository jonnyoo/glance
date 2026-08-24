//
//  EnrollmentDirectionSweep.swift
//  glance
//
//  A reusable full-screen "sweep of light" — several layered, blurred
//  accent-colored ribbons that accelerate across the view toward a given
//  enrollment direction. Intentionally not an arrow: the motion itself is
//  the cue. The camera preview stays visually dominant; this is atmospheric
//  guidance, not a HUD.
//
//  Curved trajectories are driven by an `Animatable` modifier whose
//  `animatableData` is sweep progress. Animating `.offset` directly would
//  interpolate the resolved offset and flatten any arc back into a straight
//  line; interpolating progress and evaluating a quadratic Bézier each
//  frame is what keeps the path curved.
//

import SwiftUI

enum EnrollmentSweepDirection: CaseIterable, Hashable {
    case left, right, up, down, topLeft, topRight, bottomLeft, bottomRight

    /// Unit travel vector in SwiftUI screen space (x right, y down). The
    /// sweep originates on the opposite side and exits in this direction —
    /// `.left` travels right → left, `.up` travels bottom → top.
    var travel: CGVector {
        let d = CGFloat(1 / sqrt(2.0))
        switch self {
        case .left:        return CGVector(dx: -1, dy:  0)
        case .right:       return CGVector(dx:  1, dy:  0)
        case .up:          return CGVector(dx:  0, dy: -1)
        case .down:        return CGVector(dx:  0, dy:  1)
        case .topLeft:     return CGVector(dx: -d, dy: -d)
        case .topRight:    return CGVector(dx:  d, dy: -d)
        case .bottomLeft:  return CGVector(dx: -d, dy:  d)
        case .bottomRight: return CGVector(dx:  d, dy:  d)
        }
    }

    init?(pose: EnrollmentPose) {
        switch pose {
        case .center:      return nil
        case .left:        self = .left
        case .right:       self = .right
        case .top:         self = .up
        case .bottom:      self = .down
        case .topLeft:     self = .topLeft
        case .topRight:    self = .topRight
        case .bottomLeft:  self = .bottomLeft
        case .bottomRight: self = .bottomRight
        }
    }

    var previewLabel: String {
        switch self {
        case .left:        return "Left"
        case .right:       return "Right"
        case .up:          return "Up"
        case .down:        return "Down"
        case .topLeft:     return "Top left"
        case .topRight:    return "Top right"
        case .bottomLeft:  return "Bottom left"
        case .bottomRight: return "Bottom right"
        }
    }
}

struct EnrollmentDirectionSweep: View {
    let direction: EnrollmentSweepDirection

    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(Self.specs) { spec in
                    SweepStreak(
                        spec: spec,
                        direction: direction,
                        canvasSize: geo.size
                    )
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .opacity(OnboardingMetrics.sweepMasterOpacity)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

// MARK: - Streak specs

private struct StreakSpec: Identifiable {
    let id: Int
    let thickness: CGFloat
    let lengthFactor: CGFloat
    let blurScale: CGFloat
    let peakOpacity: Double
    let duration: Double
    let delay: Double
    /// Perpendicular offset across the travel band, as a fraction of the
    /// shorter canvas edge. Signed so streaks fan out rather than stacking.
    let lateral: CGFloat
    /// Quadratic Bézier curvature, as a fraction of the shorter canvas
    /// edge. Opposite signs arc opposite ways so the trail feels organic.
    let bow: CGFloat
    /// Progress at which opacity reaches zero. Values below 1 die mid-
    /// screen; 1.0 runs fully off the far edge.
    let fadeOutAt: Double
    let hasHighlight: Bool
    let isVivid: Bool
}

extension EnrollmentDirectionSweep {
    /// ~42 ribbons fanned across the same perpendicular span as before —
    /// denser packing, not a wider field.
    fileprivate static let specs: [StreakSpec] = makeSpecs()

    private static func makeSpecs() -> [StreakSpec] {
        let count = 42
        let laterals = (0..<count).map { index -> CGFloat in
            let t = CGFloat(index) / CGFloat(count - 1)
            return -0.86 + t * 1.72
        }
        return laterals.enumerated().map { index, lateral in
            let lane = index % 7
            let edgeFade = 1 - abs(Double(lateral)) * 0.22
            let isVivid = index % 6 == 1 || index % 6 == 4
            let heavyBlur = index % 4 != 0
            let blurScale: CGFloat = [1.35, 1.16, 0.96, 1.22, 0.82, 1.32, 1.02][lane]
                * (heavyBlur ? 2.6 : 1.1)
            let peakBase: Double = [0.58, 0.72, 0.80, 0.52, 0.66, 0.42, 0.48][lane]
            return StreakSpec(
                id: index,
                thickness: [310, 190, 105, 155, 72, 230, 88][lane],
                lengthFactor: [1.16, 0.94, 0.72, 0.86, 0.54, 1.04, 0.62][lane],
                blurScale: blurScale,
                peakOpacity: peakBase * edgeFade * (isVivid ? 1.4 : 1),
                duration: [1.22, 1.08, 0.98, 1.16, 0.94, 1.28, 1.04][lane],
                delay: [0.00, 0.03, 0.06, 0.015, 0.08, 0.04, 0.065][lane]
                    + Double(index % 4) * 0.008,
                lateral: lateral,
                bow: [0.18, -0.14, 0.10, -0.22, 0.26, 0.08, -0.12][lane],
                fadeOutAt: 1,
                hasHighlight: isVivid || lane == 2 || lane == 4,
                isVivid: isVivid
            )
        }
    }
}

// MARK: - Geometry

private struct SweepGeometry {
    let start: CGPoint
    let end: CGPoint
    let control: CGPoint
    let canvasSize: CGSize
    let length: CGFloat
    let rotationDrift: Double

    init(spec: StreakSpec, direction: EnrollmentSweepDirection, canvasSize: CGSize) {
        self.canvasSize = canvasSize
        let travel = direction.travel
        let perp = CGVector(dx: -travel.dy, dy: travel.dx)
        let shortEdge = min(canvasSize.width, canvasSize.height)
        // Enter a bit early. The far end stops short of a full off-screen
        // exit so the ease-out is still on-camera.
        let diagonal = hypot(canvasSize.width, canvasSize.height)
        let startSpan = diagonal * 0.58
        let endSpan = diagonal * 0.50
        length = max(shortEdge * spec.lengthFactor * 0.55, 180)
        let cx = canvasSize.width / 2
        let cy = canvasSize.height / 2
        // Spread along the true perpendicular screen axis (height for a
        // horizontal sweep, width for a vertical one) so ribbons fan across
        // most of the display instead of a narrow center band.
        let perpExtent = abs(perp.dx) * canvasSize.width + abs(perp.dy) * canvasSize.height
        let lateral = spec.lateral * perpExtent * 0.46
        start = CGPoint(
            x: cx - travel.dx * startSpan + perp.dx * lateral,
            y: cy - travel.dy * startSpan + perp.dy * lateral
        )
        end = CGPoint(
            x: cx + travel.dx * endSpan + perp.dx * lateral,
            y: cy + travel.dy * endSpan + perp.dy * lateral
        )
        let mid = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2)
        let bow = spec.bow * shortEdge * 0.20
        control = CGPoint(x: mid.x + perp.dx * bow, y: mid.y + perp.dy * bow)
        rotationDrift = Double(spec.bow.sign == .minus ? -0.05 : 0.05)
    }

    func point(at t: Double) -> CGPoint {
        let u = 1 - t
        return CGPoint(
            x: u * u * start.x + 2 * u * t * control.x + t * t * end.x,
            y: u * u * start.y + 2 * u * t * control.y + t * t * end.y
        )
    }

    /// Tangent heading of the Bézier at `t`, in radians.
    func heading(at t: Double) -> Double {
        let dx = 2 * (1 - t) * (control.x - start.x) + 2 * t * (end.x - control.x)
        let dy = 2 * (1 - t) * (control.y - start.y) + 2 * t * (end.y - control.y)
        return atan2(dy, dx)
    }

    func opacity(at t: Double, peak: Double, fadeOutAt: Double) -> Double {
        let fadeInEnd = 0.07
        // Hold full opacity through the fast middle, then dissolve during
        // the ease-out so the slowdown is still visible.
        let fadeOutStart = 0.7
        if t <= 0 || t >= fadeOutAt { return 0 }
        if t < fadeInEnd {
            let u = t / fadeInEnd
            return peak * (u * u * (3 - 2 * u))
        }
        if t > fadeOutStart {
            let span = max(fadeOutAt - fadeOutStart, 0.001)
            let u = (t - fadeOutStart) / span
            let s = u * u * (3 - 2 * u)
            return peak * (1 - s)
        }
        return peak
    }
}

// MARK: - Motion

/// Position, rotation and opacity all derive from one animated `progress`,
/// so a single ease-in timing curve governs the whole streak. This is a
/// `View` rather than a `ViewModifier` so SwiftUI interpolates
/// `animatableData` on the view itself — the reliable path for evaluating
/// a Bézier each frame instead of sliding between endpoints.
private struct SweepMovingContainer<Content: View>: View, Animatable {
    var progress: Double
    let geometry: SweepGeometry
    let peakOpacity: Double
    let fadeOutAt: Double
    let content: Content

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let t = min(max(progress, 0), 1)
        let point = geometry.point(at: t)
        let cx = geometry.canvasSize.width / 2
        let cy = geometry.canvasSize.height / 2
        // Rotate first, then translate. Offset does not change the view's
        // layout center, so rotating *after* offset spins the translation
        // around the screen center and sends most directions the wrong way
        // (left↔right flip, up/down sliding sideways).
        content
            .rotationEffect(.radians(geometry.heading(at: t) + geometry.rotationDrift * t))
            .offset(x: point.x - cx, y: point.y - cy)
            .opacity(geometry.opacity(at: t, peak: peakOpacity, fadeOutAt: fadeOutAt))
    }
}

// MARK: - Streak view

private struct SweepStreak: View {
    let spec: StreakSpec
    let direction: EnrollmentSweepDirection
    let canvasSize: CGSize

    @State private var progress: Double = 0

    var body: some View {
        let geometry = SweepGeometry(spec: spec, direction: direction, canvasSize: canvasSize)
        SweepMovingContainer(
            progress: progress,
            geometry: geometry,
            peakOpacity: spec.peakOpacity,
            fadeOutAt: spec.fadeOutAt,
            content: layers(length: geometry.length)
        )
        .onAppear { runSweep() }
    }

    private func layers(length: CGFloat) -> some View {
        ZStack {
            streakLayer(
                length: length,
                thickness: spec.thickness * 2.35,
                blur: 78 * spec.blurScale,
                opacity: spec.isVivid ? 0.28 : 0.16,
                colors: [GlanceTheme.accent, GlanceTheme.accentBright]
            )
            streakLayer(
                length: length,
                thickness: spec.thickness,
                blur: 34 * spec.blurScale,
                opacity: spec.isVivid ? 0.48 : 0.30,
                colors: spec.isVivid
                    ? [GlanceTheme.accentBright, GlanceTheme.accentPale]
                    : [GlanceTheme.accent, GlanceTheme.accentBright]
            )
            streakLayer(
                length: length,
                thickness: spec.thickness * 0.42,
                blur: 14 * spec.blurScale,
                opacity: spec.isVivid ? 0.62 : 0.38,
                colors: [GlanceTheme.accentBright, GlanceTheme.accentPale]
            )
            if spec.hasHighlight {
                streakLayer(
                    length: length * 0.72,
                    thickness: spec.thickness * 0.12,
                    blur: 6,
                    opacity: spec.isVivid ? 0.36 : 0.20,
                    colors: [GlanceTheme.accentPale, Color.white]
                )
            }
        }
        .compositingGroup()
    }

    private func streakLayer(
        length: CGFloat,
        thickness: CGFloat,
        blur: CGFloat,
        opacity: Double,
        colors: [Color]
    ) -> some View {
        Capsule()
            .fill(
                LinearGradient(
                    stops: [
                        .init(color: colors[0].opacity(0), location: 0),
                        .init(color: colors[0].opacity(0.6), location: 0.18),
                        .init(color: colors[1], location: 0.55),
                        .init(color: colors[1].opacity(0.85), location: 0.82),
                        .init(color: colors[1].opacity(0), location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
            .frame(width: length, height: thickness)
            .blur(radius: blur)
            .opacity(opacity)
    }

    private func runSweep() {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) { progress = 0 }
        // Hop a turn so the reset isn't coalesced into the forward animation.
        Task { @MainActor in
            withAnimation(
                .timingCurve(0.68, 0.0, 0.32, 1.0, duration: spec.duration)
                .delay(spec.delay)
            ) {
                progress = 1
            }
        }
    }
}

// MARK: - Previews

#Preview("All directions") {
    let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
    ]
    LazyVGrid(columns: columns, spacing: 8) {
        ForEach(EnrollmentSweepDirection.allCases, id: \.self) { direction in
            ZStack(alignment: .topLeading) {
                Color.black
                EnrollmentDirectionSweep(direction: direction)
                Text(direction.previewLabel)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(8)
            }
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }
    .padding(12)
    .frame(width: 920, height: 360)
    .background(Color.black)
}

#Preview("Cycling") {
    struct CyclingSweepPreview: View {
        @State private var index = 0
        private let directions = EnrollmentSweepDirection.allCases

        var body: some View {
            ZStack(alignment: .topLeading) {
                Color.black
                EnrollmentDirectionSweep(direction: directions[index])
                    .id(directions[index])
                    .transition(.opacity)
                    .animation(.easeInOut(duration: OnboardingMetrics.sweepDirectionCrossfade), value: index)
                Text(directions[index].previewLabel)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(16)
            }
            .frame(width: 900, height: 560)
            .task {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(4.2))
                    index = (index + 1) % directions.count
                }
            }
        }
    }

    return CyclingSweepPreview()
}
