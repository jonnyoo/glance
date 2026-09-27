import CoreGraphics

/// A face rectangle includes background beside the jaw and temples. Use the
/// detected jaw outline, extending its two temples to the rectangle's top so
/// forehead highlights remain visible. Coordinates are normalized to the
/// clipped crop, with a top-left origin, like DetectedFace.boundingBox.
nonisolated enum GlareFaceRegion {
    static func polygon(contour: [CGPoint], faceBounds: CGRect, imageSize: CGSize) -> [CGPoint]? {
        let crop = faceBounds.intersection(CGRect(origin: .zero, size: imageSize))
        guard contour.count >= 5, crop.width > 0, crop.height > 0,
              contour.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              let first = contour.first, let last = contour.last,
              abs(first.x - last.x) >= crop.width * 0.4 else { return nil }
        let points = contour + [CGPoint(x: first.x, y: faceBounds.minY), CGPoint(x: last.x, y: faceBounds.minY)]
        let normalized = points.map { CGPoint(x: ($0.x - crop.minX) / crop.width, y: ($0.y - crop.minY) / crop.height) }
        guard normalized.allSatisfy({ (-0.1...1.1).contains($0.x) && (-0.1...1.1).contains($0.y) }) else { return nil }
        // Hull avoids dependence on contour traversal direction and retains
        // the outer facial surface rather than cutting across a cheek.
        let sorted = normalized.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        func turn(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
            (b.x-a.x)*(c.y-a.y) - (b.y-a.y)*(c.x-a.x)
        }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for point in sorted {
            while lower.count >= 2 && turn(lower[lower.count-2], lower[lower.count-1], point) <= 0 { lower.removeLast() }
            lower.append(point)
        }
        for point in sorted.reversed() {
            while upper.count >= 2 && turn(upper[upper.count-2], upper[upper.count-1], point) <= 0 { upper.removeLast() }
            upper.append(point)
        }
        return Array(lower.dropLast()) + Array(upper.dropLast())
    }
}
