import Foundation

@main
struct ResultSelftest {
    static func main() throws {
        let pixels = Data(repeating: 128, count: 340 * 340).base64EncodedString()
        func result(_ overrides: [String: Any] = [:]) throws -> InfraredProbeResult {
            var object: [String: Any] = ["ok": true, "frames": 10,
                "width": 340, "height": 340, "pixels": pixels]
            object.merge(overrides) { _, new in new }
            return try InfraredProbeResult.decode(JSONSerialization.data(withJSONObject: object))
        }
        let image = try result().image()
        precondition(image.width == 340 && image.height == 340 && image.bitsPerPixel == 8)
        for invalid: [String: Any] in [
            ["ok": false], ["frames": 0], ["width": 640], ["height": 480],
            ["pixels": "not base64"], ["pixels": Data([0]).base64EncodedString()],
            ["pixels": Data(repeating: 0, count: 340 * 340 + 1).base64EncodedString()]
        ] {
            do {
                _ = try result(invalid).image()
                fatalError("Accepted invalid IR snapshot: \(invalid.keys)")
            } catch InfraredProbeError.invalidResponse { }
        }
        do {
            _ = try InfraredProbeResult.decode(Data(repeating: 0, count: 200_001))
            fatalError("Accepted oversized response")
        } catch InfraredProbeError.invalidResponse { }
        let check = try InfraredProbeResult.decode(Data("{\"ok\":true,\"irDescriptor\":true,\"claimCode\":-3}".utf8))
        do {
            _ = try check.image()
            fatalError("Treated descriptor discovery as a captured frame")
        } catch InfraredProbeError.invalidResponse { }
        print("IR response validation passed (valid frame, corrupt/short/oversized data, wrong dimensions, no frames, descriptor-only response).")
    }
}
