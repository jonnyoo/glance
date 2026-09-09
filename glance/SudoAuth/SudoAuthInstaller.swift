//
//  SudoAuthInstaller.swift
//  glance
//
//  Installs pam_glance.so and ensures /etc/pam.d/sudo_local lists it above
//  pam_tid.so via pam_glance_install.sh + osascript admin privileges.
//

import Foundation

enum SudoAuthInstaller {
    static let moduleInstallPath = "/usr/local/lib/pam/pam_glance.so"
    static let sudoLocalPath = "/etc/pam.d/sudo_local"

    enum Status: Equatable {
        case unknown
        case missingModule
        case missingPamLine
        case installed
        case error(String)

        var isOperational: Bool { self == .installed }

        var label: String {
            switch self {
            case .unknown: return "Checking…"
            case .missingModule: return "PAM module missing from this build"
            case .missingPamLine: return "Not installed into sudo yet"
            case .installed: return "Installed"
            case .error(let message): return message
            }
        }
    }

    enum InstallError: LocalizedError {
        case moduleMissingFromBundle
        case scriptMissingFromBundle
        case privilegedCommandFailed(String)

        var errorDescription: String? {
            switch self {
            case .moduleMissingFromBundle:
                return "pam_glance.so is missing from this app build. Rebuild Glance so the Embed pam_glance phase can produce it."
            case .scriptMissingFromBundle:
                return "pam_glance install script missing from this app build."
            case .privilegedCommandFailed(let detail):
                return detail
            }
        }
    }

    static func currentStatus() -> Status {
        let moduleOK = FileManager.default.isReadableFile(atPath: moduleInstallPath)
        let bundledOK = bundledModuleURL().map { FileManager.default.isReadableFile(atPath: $0.path) } ?? false
        if !moduleOK && !bundledOK {
            return .missingModule
        }
        if !moduleOK {
            return .missingPamLine
        }

        // /etc/pam.d is often unreadable without Full Disk Access. If we
        // can't read it but the .so is already installed system-wide, treat
        // as installed so the socket listener can start (sudo_local was
        // verified at install time).
        guard let contents = try? String(contentsOfFile: sudoLocalPath, encoding: .utf8) else {
            return .installed
        }
        let hasGlance = contents.split(separator: "\n").contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.hasPrefix("#") && trimmed.contains("pam_glance.so")
        }
        return hasGlance ? .installed : .missingPamLine
    }

    static func bundledModuleURL() -> URL? {
        Bundle.main.url(forResource: "pam_glance", withExtension: "so")
    }

    static func bundledInstallScriptURL() -> URL? {
        Bundle.main.url(forResource: "pam_glance_install", withExtension: "sh")
    }

    @MainActor
    static func install() async throws {
        guard let moduleURL = bundledModuleURL(),
              FileManager.default.isReadableFile(atPath: moduleURL.path) else {
            throw InstallError.moduleMissingFromBundle
        }
        guard let scriptURL = bundledInstallScriptURL(),
              FileManager.default.isReadableFile(atPath: scriptURL.path) else {
            throw InstallError.scriptMissingFromBundle
        }

        // Copy script to a root-readable temp path — app bundle paths can
        // contain spaces and the script must be executable by the admin shell.
        let tmpScript = FileManager.default.temporaryDirectory
            .appendingPathComponent("pam_glance_install.sh")
        try? FileManager.default.removeItem(at: tmpScript)
        try FileManager.default.copyItem(at: scriptURL, to: tmpScript)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: tmpScript.path
        )

        let cmd = "\(shellEscape(tmpScript.path)) install \(shellEscape(moduleURL.path))"
        try runAdminShell(cmd)
    }

    @MainActor
    static func uninstallModuleLine() async throws {
        guard let scriptURL = bundledInstallScriptURL(),
              FileManager.default.isReadableFile(atPath: scriptURL.path) else {
            // Nothing to uninstall if the script was never bundled.
            return
        }
        let tmpScript = FileManager.default.temporaryDirectory
            .appendingPathComponent("pam_glance_install.sh")
        try? FileManager.default.removeItem(at: tmpScript)
        try FileManager.default.copyItem(at: scriptURL, to: tmpScript)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: tmpScript.path
        )
        let cmd = "\(shellEscape(tmpScript.path)) uninstall"
        try runAdminShell(cmd)
    }

    private static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func runAdminShell(_ command: String) throws {
        let encoded = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(encoded)\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", appleScript]
        let errPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw InstallError.privilegedCommandFailed(
                message?.isEmpty == false ? message! : "Administrator authorization failed."
            )
        }
    }
}
