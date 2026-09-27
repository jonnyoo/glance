// Run from a lab-style test bundle with the compiled ArcFace model. No camera.
import Foundation
import CoreGraphics

@main
struct ModelSelfTest {
    static func main() async {
        do {
            let model = try ArcFaceEmbedder()
            let context = CGContext(data: nil, width: 112, height: 112,
                bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(gray: 0.4, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: 112, height: 112))
            let image = context.makeImage()!
            let vector = try model.embedding(for: image)
            precondition(vector.count == 512 && vector.allSatisfy(\.isFinite))
            let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
            precondition(abs(norm - 1) < 0.001)
            do {
                _ = try await InfraredFaceAnalyzer().sample(from: image, captureID: UUID())
                fatalError("A blank image must not produce a face sample")
            } catch InfraredFaceAnalysisError.faceCount(0) {
                print("Bundled model inference passed; blank image rejected before reference enrollment.")
            }
        } catch {
            print("Model self-test failed: \(error.localizedDescription)"); exit(1)
        }
    }
}
