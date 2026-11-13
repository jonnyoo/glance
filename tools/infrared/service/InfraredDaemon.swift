import Foundation
import SystemConfiguration

private func consoleUser() -> uid_t? {
    var uid: uid_t = 0
    guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as String?,
          name != "loginwindow", uid >= 501 else { return nil }
    return uid
}

/// A single camera job across all connections. C storage remains alive until
/// capture returns; cancellation and destruction use the same lock.
private final class CaptureBroker: @unchecked Sendable {
    private let lock = NSLock()
    private var shuttingDown = false
    private var active: (owner: UUID, request: String, job: OpaquePointer)?
    private let worker = DispatchQueue(label: "glance.ir.capture")

    func capture(owner: UUID, request: String, user: uid_t,
                 isConnected: @escaping () -> Bool,
                 reply: @escaping (Data?, String?) -> Void) {
        guard UUID(uuidString: request) != nil, request.utf8.count == 36,
              consoleUser() == user, isConnected() else {
            reply(nil, "The active user session is required."); return
        }
        lock.lock()
        guard !shuttingDown else { lock.unlock(); reply(nil, "The camera helper is stopping."); return }
        guard active == nil else { lock.unlock(); reply(nil, "The infrared camera is busy."); return }
        guard let job = brio_ir_create() else {
            lock.unlock(); reply(nil, "Could not allocate camera memory."); return
        }
        active = (owner, request, job)
        lock.unlock()
        worker.async { [self] in
            let watchdog = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            let deadline = DispatchTime.now() + .seconds(20)
            watchdog.schedule(deadline: .now(), repeating: .milliseconds(100))
            watchdog.setEventHandler { [self] in
                if !isConnected() || consoleUser() != user || DispatchTime.now() >= deadline {
                    cancel(owner: owner, request: request)
                }
            }
            watchdog.resume()
            var count = 0
            let bytes = brio_ir_snapshot(job, &count)
            let data = bytes.flatMap { count <= 200_000 ? Data(bytes: $0, count: count) : nil }
            brio_ir_free_response(bytes, count)
            watchdog.cancel()
            lock.lock()
            active = nil
            brio_ir_destroy(job)
            lock.unlock()
            guard isConnected(), consoleUser() == user else {
                reply(nil, "The user session changed during capture."); return
            }
            reply(data, data == nil ? "The infrared helper returned no usable response." : nil)
        }
    }

    func shutdown() {
        lock.lock()
        shuttingDown = true
        if let active { brio_ir_cancel(active.job) }
        lock.unlock()
        // Let USB cleanup restore the camera before launchd removes the job.
        worker.async { exit(0) }
    }

    func cancel(owner: UUID, request: String? = nil) {
        lock.lock()
        if let active, active.owner == owner, request == nil || active.request == request {
            brio_ir_cancel(active.job)
        }
        lock.unlock()
    }
}

private final class ClientSession: NSObject, InfraredServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var connected = true
    private let owner = UUID()
    private let user: uid_t
    private let broker: CaptureBroker

    init(user: uid_t, broker: CaptureBroker) { self.user = user; self.broker = broker }
    private var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return connected }
    func disconnect() {
        lock.lock(); connected = false; lock.unlock()
        broker.cancel(owner: owner)
    }
    func capture(_ requestID: String, withReply reply: @escaping (Data?, String?) -> Void) {
        broker.capture(owner: owner, request: requestID, user: user,
                       isConnected: { [self] in isConnected }, reply: reply)
    }
    func cancel(_ requestID: String) { broker.cancel(owner: owner, request: requestID) }
    func ping(withReply reply: @escaping (String) -> Void) {
        reply(isConnected && consoleUser() == user ? "ready" : "unavailable")
    }
}

private final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let broker = CaptureBroker()
    func shutdown() { broker.shutdown() }
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard let user = consoleUser(), connection.effectiveUserIdentifier == user else { return false }
        let session = ClientSession(user: user, broker: broker)
        connection.exportedInterface = NSXPCInterface(with: InfraredServiceProtocol.self)
        connection.exportedObject = session
        connection.invalidationHandler = { session.disconnect() }
        connection.interruptionHandler = { session.disconnect() }
        connection.resume()
        return true
    }
}

@main
private enum InfraredDaemon {
    static func main() {
        guard geteuid() == 0 else { exit(1) }
        let delegate = ListenerDelegate()
        let listener = NSXPCListener(machServiceName: ServiceBuildConfiguration.serviceName)
        listener.setConnectionCodeSigningRequirement(ServiceBuildConfiguration.clientRequirement)
        listener.delegate = delegate
        signal(SIGTERM, SIG_IGN)
        let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termination.setEventHandler { delegate.shutdown() }
        termination.resume()
        listener.resume()
        withExtendedLifetime((delegate, termination)) { RunLoop.current.run() }
    }
}
