//
//  SudoAuthServer.swift
//  glance
//
//  Unix-domain socket listener for pam_glance.so. Accepts one auth at a
//  time; concurrent connections get UNAVAIL so PAM falls through to Touch ID.
//

import Foundation

@MainActor
final class SudoAuthServer {
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var isBusy = false
    private var authTask: Task<Void, Never>?
    private let runner = SudoFaceAuthRunner()

    private(set) var isListening = false

    func startIfNeeded() {
        guard !isListening else { return }
        guard SecureCredentialManager.isSessionUnlocked else { return }
        guard GlanceSettings.shared.isSudoFaceEnabled else { return }

        let path = SudoAuthProtocol.currentUserSocketPath
        unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { cPath in
            withUnsafeMutableBytes(of: &addr.sun_path) { buf in
                let count = min(strlen(cPath) + 1, buf.count)
                _ = memcpy(buf.baseAddress, cPath, count)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            NSLog("SudoAuthServer: bind(%@) failed errno=%d", path, err)
            close(fd)
            return
        }

        // Root (sudo/PAM) must be able to connect; owner-only would block it.
        chmod(path, 0o666)

        guard listen(fd, 2) == 0 else {
            close(fd)
            unlink(path)
            return
        }

        listenFD = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        acceptSource = source
        isListening = true
    }

    func stop() {
        authTask?.cancel()
        authTask = nil
        isBusy = false
        acceptSource?.cancel()
        acceptSource = nil
        listenFD = -1
        unlink(SudoAuthProtocol.currentUserSocketPath)
        isListening = false
    }

    private func acceptConnection() {
        guard listenFD >= 0 else { return }
        let client = accept(listenFD, nil, nil)
        guard client >= 0 else { return }

        if isBusy || !SecureCredentialManager.isSessionUnlocked || !GlanceSettings.shared.isSudoFaceEnabled {
            writeResult(.unavailable, to: client)
            close(client)
            return
        }

        isBusy = true
        authTask = Task { @MainActor [weak self] in
            guard let self else {
                Self.writeResultStatic(.unavailable, to: client)
                close(client)
                return
            }
            let timeout = self.readTimeout(from: client)
            let result = await self.runner.authenticate(timeout: TimeInterval(timeout))
            if Task.isCancelled {
                Self.writeResultStatic(.deny, to: client)
            } else {
                self.writeResult(result, to: client)
            }
            close(client)
            self.isBusy = false
            self.authTask = nil
        }
    }

    /// Protocol: optional `"AUTH <seconds>\n"`; empty/unknown → default timeout.
    private func readTimeout(from fd: Int32) -> UInt32 {
        var buffer = [UInt8](repeating: 0, count: 64)
        usleep(150_000)
        let n = read(fd, &buffer, buffer.count)
        guard n > 0 else { return SudoAuthProtocol.defaultTimeoutSeconds }
        let line = String(bytes: buffer.prefix(Int(n)), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if line.hasPrefix("AUTH") {
            let parts = line.split(separator: " ")
            if parts.count >= 2, let value = UInt32(parts[1]) {
                return min(max(value, 1), SudoAuthProtocol.maxTimeoutSeconds)
            }
        }
        return SudoAuthProtocol.defaultTimeoutSeconds
    }

    private func writeResult(_ result: SudoAuthProtocol.Result, to fd: Int32) {
        Self.writeResultStatic(result, to: fd)
    }

    private static func writeResultStatic(_ result: SudoAuthProtocol.Result, to fd: Int32) {
        let payload = result.rawValue + "\n"
        payload.withCString { ptr in
            _ = write(fd, ptr, strlen(ptr))
        }
    }
}
