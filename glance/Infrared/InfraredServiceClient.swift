import Foundation
import ServiceManagement
import Observation
import AVFoundation

@Observable @MainActor
final class InfraredServiceManager {
    private(set) var state: SMAppService.Status = .notFound
    private(set) var message = ""
    var available: Bool {
        Self.configuration != nil && FileManager.default.isExecutableFile(atPath:
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/GlanceIRService").path)
    }
    var enabled: Bool { state == .enabled }
    var needsApproval: Bool { state == .requiresApproval }
    var registered: Bool { enabled || needsApproval }

    nonisolated static var configuration: (name: String, requirement: String)? {
        guard let name = Bundle.main.object(forInfoDictionaryKey: "GlanceIRServiceName") as? String,
              let requirement = Bundle.main.object(forInfoDictionaryKey: "GlanceIRServiceRequirement") as? String,
              !name.isEmpty, !requirement.isEmpty else { return nil }
        return (name, requirement)
    }
    private var service: SMAppService? {
        Self.configuration.map { SMAppService.daemon(plistName: $0.name + ".plist") }
    }
    init() { refresh() }
    func refresh() { state = service?.status ?? .notFound }
    func enable() {
        do {
            try service?.register()
            refresh()
            message = needsApproval
                ? "Approve the camera helper in System Settings → Login Items & Extensions."
                : "Camera helper enabled. It captures only during infrared enrollment, checks or tests."
        } catch { message = error.localizedDescription; refresh() }
    }
    func disable() async {
        do {
            try await service?.unregister()
            message = "Camera helper disabled."
        } catch { message = error.localizedDescription }
        refresh()
    }
    func openSettings() { SMAppService.openSystemSettingsLoginItems() }

    nonisolated static func capture(allowPermissionPrompt: Bool = true) async throws -> InfraredProbeResult {
        guard let config = configuration else { throw InfraredProbeError.helperMissing }
        // Consent is still required even though the USB engine runs as root.
        let authorized = AVCaptureDevice.authorizationStatus(for: .video) == .authorized
        let permitted: Bool
        if authorized { permitted = true }
        else if allowPermissionPrompt { permitted = await AVCaptureDevice.requestAccess(for: .video) }
        else { permitted = false }
        guard permitted else {
            throw InfraredProbeError.execution("Allow camera access in System Settings to run the IR test.")
        }
        let request = InfraredServiceRequest(name: config.name, requirement: config.requirement)
        let data = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { request.start($0) }
        } onCancel: { request.cancel() }
        try Task.checkCancellation()
        return try InfraredProbeResult.decode(data)
    }
}

/// Every exit resolves once, even when cancellation, timeout and XPC errors race.
nonisolated private final class InfraredServiceRequest: @unchecked Sendable {
    private let lock = NSLock()
    private let connection: NSXPCConnection
    private let requestID = UUID().uuidString
    private var continuation: CheckedContinuation<Data, Error>?
    private var completed: Result<Data, Error>?
    private var timeout: DispatchWorkItem?

    init(name: String, requirement: String) {
        connection = NSXPCConnection(machServiceName: name, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: InfraredServiceProtocol.self)
        connection.setCodeSigningRequirement(requirement)
    }
    func start(_ continuation: CheckedContinuation<Data, Error>) {
        lock.lock()
        if let completed { lock.unlock(); continuation.resume(with: completed); return }
        self.continuation = continuation
        connection.invalidationHandler = { [weak self] in self?.fail("The camera helper disconnected.") }
        connection.interruptionHandler = { [weak self] in self?.fail("The camera helper was interrupted.") }
        let timer = DispatchWorkItem { [weak self] in self?.fail("The camera helper timed out.") }
        timeout = timer
        connection.resume()
        // Hold the lock until the request is enqueued, so cancellation cannot
        // invalidate an unstarted connection and then allow capture to start.
        let remote = connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
            DispatchQueue.global().async {
                self?.fail("Could not connect to the camera helper. Check its approval in System Settings.")
            }
        } as? InfraredServiceProtocol
        remote?.capture(requestID) { [self] data, error in
            DispatchQueue.global().async { [self] in
                if let data { finish(.success(data)) }
                else { fail(error ?? "The camera helper could not capture an image.") }
            }
        }
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + 25, execute: timer)
        if remote == nil { fail("The camera helper interface is unavailable.") }
    }
    func cancel() { finish(.failure(CancellationError())) }
    private func fail(_ message: String) { finish(.failure(InfraredProbeError.execution(message))) }
    private func finish(_ result: Result<Data, Error>) {
        lock.lock()
        guard completed == nil else { lock.unlock(); return }
        completed = result
        let pending = continuation
        continuation = nil
        timeout?.cancel(); timeout = nil
        lock.unlock()
        // Invalidation cancels the owning service session's active capture.
        connection.invalidate()
        pending?.resume(with: result)
    }
}
