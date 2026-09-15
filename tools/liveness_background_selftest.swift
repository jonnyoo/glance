//
//  liveness_background_selftest.swift
//  glance (tools)
//
//  Offline test for the spoof cues that look at pixels around the face,
//  checking both directions: a device held up to the camera must still
//  deny, and ordinary background (a monitor, window, lamp or picture frame
//  behind the head) must not. Unlike `liveness_selftest.swift` this one
//  runs the real Vision rectangle detector and the real glare extractor, on
//  synthetic frames and crops drawn with CoreGraphics, so it needs
//  FaceDetector.swift but still no camera or ArcFace model:
//
//      swiftc -O -o /tmp/liveness_background_selftest \
//        glance/FaceDetector.swift \
//        glance/Liveness/DeviceBezelDetector.swift \
//        glance/Liveness/LandmarkGeometry.swift \
//        glance/Liveness/GeometryLiveness.swift \
//        glance/Liveness/GlareCue.swift \
//        glance/Liveness/GlareCueExtractor.swift \
//        glance/Liveness/LivenessCues.swift \
//        glance/Liveness/LivenessScoring.swift \
//        tools/liveness_background_selftest.swift \
//      && /tmp/liveness_background_selftest
//
//  No face pixels are drawn in the Vision scenes: Vision fits a quad around
//  a flat synthetic face blob, which would muddy which rectangle is under
//  test. The detector only ever reads the face as a box, so the box is
//  passed in directly and the head is drawn as background colour where it
//  should hide part of a rectangle. Heads hide only a small part of any
//  outline: once most of an edge is gone Vision reports no rectangle at
//  all, and a scene with nothing detected can't show the fix.
//

import Foundation
import CoreGraphics

// MARK: - Synthetic frames

/// Defaults to a 640x360 working frame (what `CameraManager` hands Vision
/// from a 16:9 camera), described in the same top-left/y-down pixel space
/// as `DetectedFace.boundingBox`.
private final class Scene {
    let width: Int
    let height: Int
    private let context: CGContext
    private static let background = CGColor(red: 0.55, green: 0.52, blue: 0.5, alpha: 1)

    init(width: Int = 640, height: Int = 360) {
        self.width = width
        self.height = height
        context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(Self.background)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }

    private func flipped(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height)
    }

    func fill(_ rect: CGRect, gray: CGFloat) {
        context.setFillColor(CGColor(red: gray, green: gray, blue: gray * 1.05, alpha: 1))
        context.fill(flipped(rect))
    }

    func outline(_ rect: CGRect, gray: CGFloat, lineWidth: CGFloat) {
        context.setStrokeColor(CGColor(red: gray, green: gray * 0.8, blue: gray * 0.6, alpha: 1))
        context.setLineWidth(lineWidth)
        context.stroke(flipped(rect).insetBy(dx: lineWidth / 2, dy: lineWidth / 2))
    }

    /// A head in front of the scene, blending into the wall so only what it hides matters.
    func occlude(_ rect: CGRect) {
        context.setFillColor(Self.background)
        context.fillEllipse(in: flipped(rect))
    }

    /// Dark body, lit screen — a phone held up in portrait.
    func phone(body: CGRect) {
        fill(body, gray: 0.05)
        fill(body.insetBy(dx: body.width * 0.06, dy: body.height * 0.05), gray: 0.85)
    }

    /// Warm skin: bright, but outside the glare extractor's neutral-white test.
    func skin(_ rect: CGRect) {
        context.setFillColor(CGColor(red: 0.8, green: 0.6, blue: 0.5, alpha: 1))
        context.fillEllipse(in: flipped(rect))
    }

    /// Clipped neutral white: a lamp, a blown-out window, or glare off a screen.
    func white(_ rect: CGRect) {
        context.setFillColor(CGColor(red: 0.99, green: 0.99, blue: 0.99, alpha: 1))
        context.fill(flipped(rect))
    }

    var image: CGImage { context.makeImage()! }
}

private func overlap(_ rect: CGRect, _ face: CGRect) -> CGFloat {
    let intersection = rect.intersection(face)
    return intersection.isNull ? 0 : (intersection.width * intersection.height) / (face.width * face.height)
}

/// The rule the core-containment fix replaced: the whole face box, with 10% slack per side, inside
/// the rectangle. A cut-face fixture must fail it, or its PASS doesn't show the fix.
private func enclosesWholeFace(_ rect: CGRect, _ face: CGRect) -> Bool {
    rect.insetBy(dx: -face.width * 0.1, dy: -face.height * 0.1).contains(face)
}

@main
struct LivenessBackgroundSelfTest {
    static func main() {
        // A failed precondition traps under -O; line buffering keeps the PASS lines before it.
        setvbuf(stdout, nil, _IOLBF, 0)
        runDeviceCandidateTests()
        runDeviceSceneTests()
        runGlareTests()
        print("\nAll background spoof-cue checks passed.")
    }

    // MARK: - Decision plumbing

    private static func cueFrame(at index: Int, deviceOverlap: CGFloat?, glare: GlareSample?) -> LivenessFrame {
        LivenessFrame(
            timestamp: Date(timeIntervalSince1970: Double(index) * 0.05), landmarks: [],
            interocularDistance: nil, yaw: nil, leftEyeAspectRatio: nil, rightEyeAspectRatio: nil,
            noseOffsetRatio: nil, hasReliableLandmarks: true,
            deviceOverlapFraction: deviceOverlap, glare: glare
        )
    }

    /// Eight frames carrying the same deny-cue inputs through the real evaluator, so a
    /// PASS here means the scan outcome, not just a number clearing a threshold.
    private static func decision(deviceOverlap: CGFloat? = nil, glare: GlareSample? = nil) -> LivenessDecision {
        var evaluator = LivenessEvaluator(mode: .light, tuning: .default)
        var window: [LivenessFrame] = []
        var snapshot = LivenessSnapshot.empty
        for index in 0..<8 {
            window.append(cueFrame(at: index, deviceOverlap: deviceOverlap, glare: glare))
            snapshot = evaluator.observe(LivenessCues.readings(window: window, geometry: GeometryLiveness.evaluate(window)))
        }
        return snapshot.decision
    }

    private static func expectDeviceDenied(_ observation: DeviceBezelObservation, _ label: String) {
        guard case .denied(.deviceDetected) = decision(deviceOverlap: observation.faceOverlapFraction) else {
            fatalError("FAIL: \(label) should deny as a device, got \(observation).")
        }
    }

    private static func expectNotDeviceDenied(_ observation: DeviceBezelObservation, _ label: String) {
        if case .denied(.deviceDetected) = decision(deviceOverlap: observation.faceOverlapFraction) {
            fatalError("FAIL: \(label) should not deny as a device, got \(observation).")
        }
    }

    // MARK: - Device bezel: candidate filter

    private static func runDeviceCandidateTests() {
        let frame = CGSize(width: 640, height: 360)
        let face = CGRect(x: 258, y: 110, width: 124, height: 124)
        let phone = CGRect(x: 235, y: 10, width: 170, height: 340)

        let held = DeviceBezelDetector.bestCandidate(among: [phone], faceBoundingBox: face, frameSize: frame)
        precondition(held.rectangle == phone && held.faceOverlapFraction == 1, "FAIL: phone around the face not selected, got \(held).")
        expectDeviceDenied(held, "a phone enclosing the face")
        print("PASS: a phone enclosing the face is still a device.")

        // A photo zoomed to fill the screen puts the face box on or slightly past the edge.
        let zoomed = CGRect(x: face.minX + 6, y: face.minY - 30, width: face.width - 12, height: 200)
        expectDeviceDenied(DeviceBezelDetector.bestCandidate(among: [zoomed], faceBoundingBox: face, frameSize: frame), "a screen the face overhangs by 5%")
        print("PASS: a face slightly overhanging the screen edge still denies.")

        // A close selfie zoomed so the screen edge cuts off the forehead, chin or a cheek: Vision's
        // face box runs 15-25% past the screen on the cut side, but the screen still holds the core.
        let cutTop = face.minY + face.height * 0.2
        let cutBottom = face.maxY - face.height * 0.25
        let cutSide = face.minX + face.width * 0.25
        let cutFaces: [(String, CGRect)] = [
            ("a screen inset 15% of the face per side", face.insetBy(dx: face.width * 0.15, dy: face.height * 0.15)),
            ("a screen inset 25% of the face per side", face.insetBy(dx: face.width * 0.25, dy: face.height * 0.25)),
            ("a screen cutting 20% off the top of the face", CGRect(x: phone.minX, y: cutTop, width: phone.width, height: phone.maxY - cutTop)),
            ("a screen cutting 25% off the bottom of the face", CGRect(x: phone.minX, y: phone.minY, width: phone.width, height: cutBottom - phone.minY)),
            ("a screen cutting 25% off one side of the face", CGRect(x: cutSide, y: phone.minY, width: phone.maxX - cutSide, height: phone.height)),
        ]
        for (label, screen) in cutFaces {
            precondition(!enclosesWholeFace(screen, face), "FAIL: \(label) no longer reproduces the whole-face drop.")
            let observation = DeviceBezelDetector.bestCandidate(among: [screen], faceBoundingBox: face, frameSize: frame)
            precondition(observation.rectangle == screen, "FAIL: \(label) was not kept as a device, got \(observation).")
            expectDeviceDenied(observation, label)
            print(String(format: "PASS: %@ still denies (overlap %.2f).", label, Double(observation.faceOverlapFraction ?? 0)))
        }

        // The old rule took the largest rectangle, which here is the background one.
        let window = CGRect(x: 0, y: 0, width: 230, height: 360)
        let crowded = DeviceBezelDetector.bestCandidate(among: [window, phone], faceBoundingBox: face, frameSize: frame)
        precondition(crowded.rectangle == phone, "FAIL: a larger background rectangle hid the phone, got \(crowded).")
        expectDeviceDenied(crowded, "a phone beside a larger background rectangle")
        print("PASS: a larger background rectangle no longer hides a held-up phone.")

        let monitorEdge = CGRect(x: 40, y: 60, width: 300, height: 200)
        precondition(overlap(monitorEdge, face) >= CGFloat(LivenessTuning.default.deviceLevel), "FAIL: fixture no longer crosses the old deny level.")
        expectNotDeviceDenied(DeviceBezelDetector.bestCandidate(among: [monitorEdge], faceBoundingBox: face, frameSize: frame), "a monitor edge cutting through the face")
        print("PASS: a background rectangle cutting through the face does not deny.")

        // Face-area ratio alone can't separate these: each tablet below is past 16x the face it shows,
        // which the fixture asserts, so only filling the view may write a rectangle off.
        func expectPastAreaRatio(_ rect: CGRect, _ face: CGRect) {
            precondition(rect.width * rect.height > face.width * face.height * 16, "FAIL: fixture \(rect) no longer exceeds 16x the face area.")
        }

        // Far distance setting: a 96px face (0.15 of frame width) in front of a window filling the view.
        let farFace = CGRect(x: 272, y: 110, width: 96, height: 96)
        let roomWindow = CGRect(x: 20, y: 12, width: 600, height: 336)
        expectPastAreaRatio(roomWindow, farFace)
        expectNotDeviceDenied(DeviceBezelDetector.bestCandidate(among: [roomWindow], faceBoundingBox: farFace, frameSize: frame), "a room-scale window around a far face")
        print("PASS: a room-scale rectangle filling the view around the face does not deny.")

        let farTablet = CGRect(x: 55, y: 20, width: 530, height: 320)
        expectPastAreaRatio(farTablet, farFace)
        expectDeviceDenied(DeviceBezelDetector.bestCandidate(among: [farTablet], faceBoundingBox: farFace, frameSize: frame), "a tablet held in frame at the Far setting")
        print("PASS: Far setting: a tablet covering ~74% of the frame, with margin around it, still denies.")

        let squareFrame = CGSize(width: 640, height: 480)
        let squareFace = CGRect(x: 272, y: 150, width: 96, height: 96)
        let squareTablet = CGRect(x: 70, y: 70, width: 500, height: 340)
        expectPastAreaRatio(squareTablet, squareFace)
        expectDeviceDenied(DeviceBezelDetector.bestCandidate(among: [squareTablet], faceBoundingBox: squareFace, frameSize: squareFrame), "a tablet held in a 4:3 frame")
        print("PASS: 4:3 camera: a 500x340 tablet around a 96px face still denies.")

        let nested = DeviceBezelDetector.bestCandidate(
            among: [CGRect(x: 262, y: 100, width: 120, height: 150), phone], faceBoundingBox: face, frameSize: frame
        )
        precondition(nested.rectangle == phone && nested.faceOverlapFraction == 1, "FAIL: should keep the rectangle covering more of the face, got \(nested).")
        print("PASS: among enclosing rectangles, the one covering the most face wins.")

        let degenerate = DeviceBezelDetector.bestCandidate(among: [phone], faceBoundingBox: CGRect(x: 300, y: 100, width: 0, height: 50), frameSize: frame)
        precondition(degenerate.faceOverlapFraction == nil, "FAIL: a zero-area face box should abstain, got \(degenerate).")
        print("PASS: a zero-area face box abstains.")
    }

    // MARK: - Device bezel: real Vision on synthetic frames

    private static func runDeviceSceneTests() {
        print("")

        // Each background scene must first reproduce the old false deny (some rectangle
        // Vision found overlaps the face past the deny level), or its PASS proves nothing.
        func expectBackgroundFixed(_ scene: Scene, face: CGRect, _ label: String) {
            let candidates = DeviceBezelDetector.rectangleCandidates(in: scene.image)
            precondition(
                candidates.contains { overlap($0, face) >= CGFloat(LivenessTuning.default.deviceLevel) },
                "FAIL: \(label): Vision found no rectangle over the face (\(candidates)), so this scene tests nothing."
            )
            expectNotDeviceDenied(DeviceBezelDetector.detect(in: scene.image, faceBoundingBox: face), label)
            print("PASS: \(label) does not deny (Vision saw \(candidates.count) rectangle(s)).")
        }

        let face = CGRect(x: 258, y: 110, width: 124, height: 124)

        let held = Scene()
        held.phone(body: CGRect(x: 235, y: 10, width: 170, height: 340))
        expectDeviceDenied(DeviceBezelDetector.detect(in: held.image, faceBoundingBox: face), "Vision: a phone held up")
        print("PASS: Vision: a phone held up denies.")

        let crowded = Scene()
        crowded.fill(CGRect(x: 10, y: 20, width: 200, height: 300), gray: 0.1)
        crowded.fill(CGRect(x: 450, y: 30, width: 180, height: 140), gray: 0.15)
        crowded.phone(body: CGRect(x: 250, y: 10, width: 150, height: 330))
        let crowdedFace = CGRect(x: 265, y: 110, width: 120, height: 120)
        expectDeviceDenied(DeviceBezelDetector.detect(in: crowded.image, faceBoundingBox: crowdedFace), "Vision: a phone in front of larger background rectangles")
        print("PASS: Vision: a phone in front of larger background rectangles denies.")

        let tablet = Scene(width: 640, height: 480)
        let tabletBody = CGRect(x: 70, y: 70, width: 500, height: 340)
        tablet.fill(tabletBody, gray: 0.05)
        tablet.fill(tabletBody.insetBy(dx: 24, dy: 24), gray: 0.85)
        expectDeviceDenied(DeviceBezelDetector.detect(in: tablet.image, faceBoundingBox: CGRect(x: 272, y: 150, width: 96, height: 96)), "Vision: a tablet held up to a 4:3 camera")
        print("PASS: Vision: a tablet held up to a 4:3 camera, past 16x the face area, denies.")

        // Neither the body nor the lit screen Vision may report holds the whole face box, so each
        // scene must show the old whole-face rule dropping everything found, or its PASS proves nothing.
        func expectCutFaceDenied(_ scene: Scene, face: CGRect, _ label: String) {
            let candidates = DeviceBezelDetector.rectangleCandidates(in: scene.image)
            precondition(
                !candidates.isEmpty && !candidates.contains { enclosesWholeFace($0, face) },
                "FAIL: \(label): Vision found \(candidates), so this scene no longer reproduces the whole-face drop."
            )
            expectDeviceDenied(DeviceBezelDetector.detect(in: scene.image, faceBoundingBox: face), label)
            print("PASS: \(label) denies (Vision saw \(candidates.count) rectangle(s)).")
        }

        // Screen edge 27% into the face from the top, body edge 20%: the forehead is cut off.
        let foreheadCut = Scene()
        let foreheadBody = CGRect(x: 235, y: 135, width: 170, height: 215)
        foreheadCut.fill(foreheadBody, gray: 0.05)
        foreheadCut.fill(foreheadBody.insetBy(dx: 8, dy: 8), gray: 0.85)
        expectCutFaceDenied(foreheadCut, face: face, "Vision: a zoomed selfie with the forehead cut off by the screen edge")

        // Screen edge 25% into the face from the bottom, body edge 19%: the chin is cut off.
        let chinCut = Scene()
        let chinBody = CGRect(x: 235, y: 10, width: 170, height: 201)
        chinCut.fill(chinBody, gray: 0.05)
        chinCut.fill(chinBody.insetBy(dx: 8, dy: 8), gray: 0.85)
        expectCutFaceDenied(chinCut, face: face, "Vision: a zoomed selfie with the chin cut off by the screen edge")

        let room = Scene()
        room.outline(CGRect(x: 20, y: 12, width: 600, height: 336), gray: 0.1, lineWidth: 14)
        let farFace = CGRect(x: 272, y: 110, width: 96, height: 96)
        room.occlude(farFace.insetBy(dx: -10, dy: -14))
        expectBackgroundFixed(room, face: farFace, "Vision: a window filling the view behind a far face")

        let monitor = Scene()
        monitor.fill(CGRect(x: 40, y: 60, width: 300, height: 200), gray: 0.08)
        let monitorFace = CGRect(x: 280, y: 90, width: 124, height: 124)
        monitor.occlude(monitorFace.insetBy(dx: 30, dy: 30))
        expectBackgroundFixed(monitor, face: monitorFace, "Vision: a monitor behind the side of the head")

        let picture = Scene()
        picture.outline(CGRect(x: 200, y: 20, width: 240, height: 180), gray: 0.3, lineWidth: 12)
        let pictureFace = CGRect(x: 258, y: 140, width: 124, height: 124)
        expectBackgroundFixed(picture, face: pictureFace, "Vision: a picture frame over the top of the head")
    }

    // MARK: - Glare: measure the face, not the crop's margin

    private static func glare(_ crop: Scene, in rect: CGRect?) -> GlareSample {
        guard let sample = GlareCueExtractor.extract(faceCrop: crop.image, measurementRect: rect) else {
            fatalError("FAIL: glare extraction returned nil for a valid crop.")
        }
        return sample
    }

    private static func glareDenies(_ sample: GlareSample) -> Bool {
        if case .denied(.glossGlare) = decision(glare: sample) { return true }
        return false
    }

    private static func glareLevel(_ sample: GlareSample) -> Float {
        LivenessCues.glossGlare(cueFrame(at: 0, deviceOverlap: nil, glare: sample)).level
    }

    private static func runGlareTests() {
        print("")
        let frameSize = CGSize(width: 640, height: 360)

        // A 200px face mid-frame: renderCrop's 1.3x box (260px) fits, and its long edge scales to 448.
        let face = CGRect(x: 220, y: 80, width: 200, height: 200)
        let cropSide: CGFloat = 448
        let faceRect = GlareCueExtractor.faceRect(of: face, inFrameOfSize: frameSize, cropSize: CGSize(width: cropSide, height: cropSide))
        let inset = cropSide * 0.15 / 1.3
        precondition(
            abs(faceRect.minX - inset) < 0.5 && abs(faceRect.minY - inset) < 0.5
                && abs(faceRect.width - cropSide / 1.3) < 0.5 && abs(faceRect.height - cropSide / 1.3) < 0.5,
            "FAIL: a centred face should be the crop's central 1/1.3, got \(faceRect)."
        )
        print("PASS: a centred face maps to the crop's central 1/1.3.")

        // Against the left frame edge renderCrop clamps (-20...240) to (0...240): margin lost on that side only.
        let edgeFace = CGRect(x: 10, y: 80, width: 200, height: 200)
        let edgeScale = cropSide / 260
        let edgeRect = GlareCueExtractor.faceRect(
            of: edgeFace, inFrameOfSize: frameSize, cropSize: CGSize(width: 240 * edgeScale, height: cropSide)
        )
        precondition(
            abs(edgeRect.minX - 10 * edgeScale) < 0.5 && abs(edgeRect.minY - 30 * edgeScale) < 0.5
                && abs(edgeRect.width - 200 * edgeScale) < 0.5,
            "FAIL: a face at the frame edge mapped to \(edgeRect)."
        )
        print("PASS: a face at the frame edge follows renderCrop's one-sided clamp.")

        func crop(_ draw: (Scene) -> Void) -> Scene {
            let scene = Scene(width: Int(cropSide), height: Int(cropSide))
            draw(scene)
            return scene
        }

        // Buffer rows must line up with the rect's top-left space, or the measured region is mirrored.
        let topBand = crop { $0.white(CGRect(x: 0, y: 0, width: cropSide, height: 100)) }
        let topHalf = glare(topBand, in: CGRect(x: 0, y: 0, width: cropSide, height: cropSide / 2))
        let bottomHalf = glare(topBand, in: CGRect(x: 0, y: cropSide / 2, width: cropSide, height: cropSide / 2))
        precondition(topHalf.specularFraction > 0.4 && bottomHalf.specularFraction == 0, "FAIL: measurement rect is flipped (top \(topHalf), bottom \(bottomHalf)).")
        precondition(glare(topBand, in: nil) == glare(topBand, in: CGRect(x: 0, y: 0, width: cropSide, height: cropSide)), "FAIL: nil should measure the whole crop.")
        print("PASS: the measurement rect is top-left like the face box, and nil still measures the whole crop.")

        let head = faceRect.insetBy(dx: 18, dy: 4)

        // Background that used to deny: it must still deny when the whole crop is measured, or the PASS proves nothing.
        let backgrounds: [(String, Scene)] = [
            ("a lamp over the shoulder", crop { $0.white(CGRect(x: 0, y: 0, width: 50, height: 90)); $0.skin(head) }),
            ("a blown-out window above the head", crop { $0.white(CGRect(x: 0, y: 0, width: cropSide, height: 50)); $0.skin(head) }),
        ]
        for (label, scene) in backgrounds {
            let whole = glare(scene, in: nil)
            precondition(glareDenies(whole), "FAIL: \(label) no longer reproduces the whole-crop false deny (\(whole)).")
            let measured = glare(scene, in: faceRect)
            precondition(!glareDenies(measured), "FAIL: \(label) should not deny as screen glare, got \(measured).")
            print(String(format: "PASS: %@ does not deny (level %.3f over the crop, %.3f over the face).", label, glareLevel(whole), glareLevel(measured)))
        }

        let clean = glare(crop { $0.skin(head) }, in: faceRect)
        precondition(!glareDenies(clean), "FAIL: a clean face should not deny, got \(clean).")
        print("PASS: a clean face does not deny.")

        let attacks: [(String, Scene)] = [
            ("glare on the face shown by a phone", crop { $0.skin(head); $0.white(CGRect(x: 150, y: 120, width: 90, height: 70)) }),
            ("a glare streak across a phone screen", crop { $0.fill(CGRect(x: 0, y: 0, width: cropSide, height: cropSide), gray: 0.85); $0.skin(head); $0.white(CGRect(x: 0, y: 160, width: cropSide, height: 40)) }),
        ]
        for (label, scene) in attacks {
            let measured = glare(scene, in: faceRect)
            precondition(glareDenies(measured), "FAIL: \(label) should still deny, got \(measured).")
            print(String(format: "PASS: %@ still denies (level %.3f over the face).", label, glareLevel(measured)))
        }
    }
}
