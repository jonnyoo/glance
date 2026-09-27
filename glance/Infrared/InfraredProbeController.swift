import Foundation
import CoreGraphics
import Observation
import Vision

/// Never connected to FaceUnlockCoordinator or SecureCredentialManager.
@Observable
@MainActor
final class InfraredProbeController {
    private(set) var isBusy = false
    private(set) var status = "Check whether the connected BRIO exposes its infrared sensor."
    private(set) var image: CGImage?
    private(set) var statistics: String?
    private(set) var canCapture = false
    private var operation: Task<Void, Never>?
    private var generation = UUID()
    let service = InfraredServiceManager()
    private let analyzer = InfraredFaceAnalyzer()
    private var reference = InfraredReference()
    private(set) var comparisonStatus = "Capture three reference scans of the same person."
    private(set) var lastComparison: InfraredSimilarity?
    private(set) var comparisons: [InfraredSimilarity] = []
    var referenceCount: Int { reference.count }
    var referenceReady: Bool { reference.isComplete }
    private enum CapturePurpose { case preview, reference, comparison }

    var helperAvailable: Bool { Self.helperURL != nil }

    private static var helperURL: URL? {
        guard let url = Bundle.main.url(forResource: "brio-ir-probe", withExtension: nil),
              FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
        return url
    }

    func check() { run(capture: false) }
    func capture() { run(capture: true) }
    func captureReference() { run(capture: true, purpose: .reference) }
    func compare() { run(capture: true, purpose: .comparison) }

    func clearReference() {
        guard !isBusy else { return }
        reference.clear()
        comparisons = []
        lastComparison = nil
        comparisonStatus = "Reference cleared. Capture three scans of the same person."
    }

    func cancel() {
        generation = UUID()
        operation?.cancel()
        operation = nil
        image = nil
        statistics = nil
        lastComparison = nil
        isBusy = false
        status = "IR test cancelled."
        comparisonStatus = "Capture cancelled. Reference scans were kept."
    }

    func clear() {
        generation = UUID()
        operation?.cancel()
        operation = nil
        image = nil
        statistics = nil
        lastComparison = nil
        canCapture = false
        isBusy = false
        status = "Check whether the connected BRIO exposes its infrared sensor."
        reference.clear()
        comparisons = []
        lastComparison = nil
        comparisonStatus = "Capture three reference scans of the same person."
    }

    private func run(capture: Bool, purpose: CapturePurpose = .preview) {
        guard !isBusy else { return }
        if purpose == .reference && reference.isComplete { return }
        if purpose == .comparison && !reference.isComplete { return }
        guard let helper = Self.helperURL else {
            status = InfraredProbeError.helperMissing.localizedDescription
            return
        }
        image = nil
        statistics = nil
        lastComparison = nil
        isBusy = true
        if !capture { canCapture = false }
        let id = UUID()
        generation = id
        service.refresh()
        status = capture
            ? (service.available ? "Look at the BRIO. Capturing for five seconds…" : "Approve the macOS prompt, then look at the BRIO. Capturing for five seconds…")
            : "Checking infrared hardware…"
        if purpose != .preview { comparisonStatus = "Capturing a new infrared scan…" }
        let process = InfraredProbeProcess()
        operation = Task {
            do {
                let result: InfraredProbeResult
                if capture && service.available {
                    guard service.enabled else {
                        throw InfraredProbeError.execution("Enable and approve the camera helper before testing infrared.")
                    }
                    result = try await InfraredServiceManager.capture()
                } else {
                    result = try await withTaskCancellationHandler {
                        try await Task.detached {
                            try process.run(helper: helper, capture: capture)
                        }.value
                    } onCancel: { process.cancel() }
                }
                try Task.checkCancellation()
                guard generation == id else { return }
                guard result.ok else {
                    throw InfraredProbeError.execution(Self.failureMessage(result))
                }
                if capture {
                    let captured = try result.image()
                    image = captured
                    let faces = try await Task.detached {
                        let request = VNDetectFaceRectanglesRequest()
                        try VNImageRequestHandler(cgImage: captured, options: [:]).perform([request])
                        return request.results?.count ?? 0
                    }.value
                    try Task.checkCancellation()
                    guard generation == id else { return }
                    let mean = result.mean ?? 0
                    statistics = "\(result.frames ?? 0) IR frames · \(result.rejected ?? 0) rejected · 340 × 340 · \(faces) face(s) detected"
                    status = mean < 5
                        ? "IR capture worked, but the image is very dark. Check the cover and lighting."
                        : "IR capture worked. Showing the brightest frame from this test. Face detection is not proof of identity or liveness."
                    if purpose != .preview {
                        comparisonStatus = "Aligning the face and measuring its features…"
                        do {
                            let sample = try await analyzer.sample(from: captured, captureID: id)
                            try Task.checkCancellation()
                            guard generation == id else { return }
                            if purpose == .reference {
                                try reference.add(sample)
                                comparisonStatus = reference.isComplete
                                    ? "Reference ready. Compare a fresh scan to measure similarity."
                                    : "Reference scan \(reference.count) of 3 captured. Keep the same person in view for the next scan."
                            } else {
                                let score = try reference.compare(sample)
                                lastComparison = score
                                comparisons.insert(score, at: 0)
                                comparisons = Array(comparisons.prefix(5))
                                comparisonStatus = "Comparison complete. This score is a measurement, not an identity or liveness decision."
                            }
                        } catch {
                            guard generation == id else { return }
                            comparisonStatus = error.localizedDescription
                        }
                    }
                } else {
                    canCapture = result.irDescriptor == true
                    status = canCapture
                        ? (service.available ? "BRIO infrared sensor found. Testing briefly interrupts its video and audio." : "BRIO infrared sensor found. Testing it temporarily takes over the camera and microphone and asks for administrator approval.")
                        : "No supported BRIO infrared sensor was found."
                }
            } catch {
                guard generation == id else { return }
                image = nil
                status = error.localizedDescription
                if purpose != .preview { comparisonStatus = "No comparison produced. " + error.localizedDescription }
            }
            guard generation == id else { return }
            isBusy = false
            operation = nil
        }
    }

    private static func failureMessage(_ result: InfraredProbeResult) -> String {
        switch result.stage {
        case "ir-descriptor":
            return "Connect exactly one supported Logitech BRIO (046d:085e). Its 340 × 340 IR interface must be available."
        case "administrator-required", "take-camera":
            return "macOS did not grant access to the BRIO's infrared interface."
        case "no-valid-ir-frames":
            return "The BRIO returned no complete infrared frames within five seconds."
        case "cancelled":
            return "IR test cancelled."
        default:
            return "IR test failed at \(result.stage ?? "unknown stage") (\(result.code ?? -1))."
        }
    }
}

/// The privileged helper is a bounded diagnostic, not an installed service. It
/// has fixed USB targets and no file-path arguments. stdout stays in memory.
nonisolated private final class InfraredProbeProcess: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        if let process, process.isRunning { process.terminate() }
        lock.unlock()
    }

    func run(helper: URL, capture: Bool) throws -> InfraredProbeResult {
        let child = Process()
        let output = Pipe()
        let errors = Pipe()
        child.standardOutput = output
        child.standardError = errors
        if capture {
            // Quote first for the shell, then for AppleScript. The only path is
            // the bundled executable; no camera-supplied string is executable.
            let shellPath = "'" + helper.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
            let command = (shellPath + " --snapshot")
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            child.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            child.arguments = ["-e", "do shell script \"\(command)\" with administrator privileges"]
        } else {
            child.executableURL = helper
            child.arguments = ["--check"]
        }
        lock.lock()
        if cancelled { lock.unlock(); throw CancellationError() }
        do { try child.run() } catch { lock.unlock(); throw error }
        process = child
        lock.unlock()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        lock.lock()
        process = nil
        let wasCancelled = cancelled
        lock.unlock()
        if wasCancelled { throw CancellationError() }
        if child.terminationStatus != 0 {
            // Never surface helper pixel data or arbitrary tool output in logs.
            let message = String(data: errorData, encoding: .utf8) ?? ""
            if message.contains("(-128)") {
                throw InfraredProbeError.execution("Administrator approval was cancelled. The IR test did not run.")
            }
            if let result = try? InfraredProbeResult.decode(data), !result.ok { return result }
            throw InfraredProbeError.execution("The IR helper could not complete the test. Check that the BRIO is connected and approve the administrator prompt.")
        }
        return try InfraredProbeResult.decode(data)
    }
}
