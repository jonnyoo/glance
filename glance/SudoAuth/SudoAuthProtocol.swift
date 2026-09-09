//
//  SudoAuthProtocol.swift
//  glance
//
//  Shared constants for the Face-for-sudo IPC path. The PAM module
//  (pam_glance.so) connects as root to a Unix-domain socket owned by the
//  logged-in user; the Glance app listens only while its Touch ID session
//  is unlocked. Keep the path format and response tokens in sync with
//  pam_glance/pam_glance.c.
//

import Foundation

enum SudoAuthProtocol {
    static let serviceName = "com.jonathan.glance.sudoauth"

    /// Default scan window when the PAM client does not send a timeout.
    static let defaultTimeoutSeconds: UInt32 = 8

    /// Absolute max the server will honor (guards a malicious / buggy client).
    static let maxTimeoutSeconds: UInt32 = 20

    enum Result: String {
        case allow = "ALLOW"
        case deny = "DENY"
        case unavailable = "UNAVAIL"
    }

    /// Socket path for the given user id — PAM resolves the uid of the
    /// account being authenticated and connects here.
    static func socketPath(uid: uid_t) -> String {
        "/tmp/\(serviceName).\(uid)"
    }

    static var currentUserSocketPath: String {
        socketPath(uid: getuid())
    }
}
