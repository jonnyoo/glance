import Foundation
import CoreGraphics

/// Diagnostic evidence only. A well-formed IR frame is not an authentication result.
nonisolated struct InfraredProbeResult: Decodable, Sendable {
    let ok: Bool
    let stage: String?
    let code: Int?
    let irDescriptor: Bool?
    let driverActive: Int?
    let claimCode: Int?
    let frames: Int?
    let rejected: Int?
    let width: Int?
    let height: Int?
    let min: Int?
    let max: Int?
    let mean: Double?
    let darkestMean: Double?
    let pixels: String?

    static func decode(_ data: Data) throws -> Self {
        guard data.count <= 200_000 else { throw InfraredProbeError.invalidResponse }
        return try JSONDecoder().decode(Self.self, from: data)
    }

    func image() throws -> CGImage {
        guard ok, let frames, frames > 0, width == 340, height == 340,
              let pixels, let data = Data(base64Encoded: pixels), data.count == 340 * 340,
              let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: 340, height: 340, bitsPerComponent: 8,
                  bitsPerPixel: 8, bytesPerRow: 340, space: CGColorSpaceCreateDeviceGray(),
                  bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider,
                  decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { throw InfraredProbeError.invalidResponse }
        return image
    }
}

nonisolated enum InfraredProbeError: LocalizedError {
    case helperMissing
    case invalidResponse
    case execution(String)

    var errorDescription: String? {
        switch self {
        case .helperMissing:
            return "This build does not include the experimental BRIO helper. See tools/infrared/README.md."
        case .invalidResponse:
            return "The IR test did not return a complete 340 × 340 infrared image."
        case .execution(let message):
            return message
        }
    }
}
