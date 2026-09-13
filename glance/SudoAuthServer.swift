import Foundation
import Darwin

/// User-session endpoint used by the root PAM module. The socket accepts only a
/// root peer, and replies with the caller's nonce so stale results cannot replay.
final class SudoAuthServer: @unchecked Sendable {
    typealias Authenticator = @MainActor @Sendable () async -> Bool

    private let queue = DispatchQueue(label: "com.jonathan.glance.sudo-auth-server", qos: .userInitiated)
    private var serverFD: Int32 = -1
    private var authenticator: Authenticator?

    private static var socketURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/glance-sudo", isDirectory: true)
            .appendingPathComponent("glance-sudo.sock")
    }

    func start(authenticator: @escaping Authenticator) {
        self.authenticator = authenticator
        queue.async { [weak self] in self?.serve() }
    }

    deinit {
        if serverFD >= 0 { Darwin.close(serverFD) }
        try? FileManager.default.removeItem(at: Self.socketURL)
    }

    private func serve() {
        let directory = Self.socketURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = chmod(directory.path, 0o700)
        unlink(Self.socketURL.path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        serverFD = fd

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout.size(ofValue: noSigPipe)))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(Self.socketURL.path.utf8CString)
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { return }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.initializeMemory(as: UInt8.self, repeating: 0)
            pathBytes.withUnsafeBytes { source in raw.copyBytes(from: source) }
        }
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else { return }
        _ = chmod(Self.socketURL.path, 0o600)
        guard listen(fd, 2) == 0 else { return }

        while true {
            let client = accept(fd, nil, nil)
            if client < 0 { continue }
            handle(client)
            Darwin.close(client)
        }
    }

    private func handle(_ client: Int32) {
        var peerUID: uid_t = 0
        var peerGID: gid_t = 0
        guard getpeereid(client, &peerUID, &peerGID) == 0, peerUID == 0 else { return }

        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))

        var buffer = [UInt8](repeating: 0, count: 128)
        let count = Darwin.read(client, &buffer, buffer.count - 1)
        guard count > 0,
              let request = String(bytes: buffer.prefix(Int(count)), encoding: .utf8)
        else { return }

        let fields = request.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ")
        guard fields.count == 2, fields[0] == "AUTH" else { return }
        let nonce = String(fields[1])
        guard nonce.count == 64, nonce.allSatisfy({ $0.isHexDigit }) else { return }

        guard let authenticator else { return }
        let semaphore = DispatchSemaphore(value: 0)
        var accepted = false
        Task { @MainActor in
            accepted = await authenticator()
            semaphore.signal()
        }
        guard semaphore.wait(timeout: .now() + 28) == .success else { return }

        let response = "\(accepted ? "OK" : "FAIL") \(nonce)\n"
        response.withCString { pointer in
            _ = Darwin.write(client, pointer, strlen(pointer))
        }
    }
}
