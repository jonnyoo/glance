//
//  LockedApp.swift
//  glance
//
//  One entry in the App Lock list. Matched against running apps by bundle identifier alone; the name and path are just
//  what the Settings list shows, captured when the app was picked.
//

import AppKit
import UniformTypeIdentifiers

struct LockedApp: Codable, Identifiable, Hashable {
    let bundleIdentifier: String
    var name: String
    /// Where the bundle was when it was picked. Only used for the icon, so going stale costs nothing but that.
    var path: String

    var id: String { bundleIdentifier }
}

extension LockedApp {
    /// Apps that must never be lockable. Glance can't sit behind its own curtain, and the Finder comes forward on every
    /// click of the desktop — locking it would make the Mac unusable rather than private.
    private static let exemptBundleIdentifiers: Set<String> = [
        Bundle.main.bundleIdentifier ?? "com.jonathan.glance",
        "com.apple.finder",
    ]

    static func canLock(bundleIdentifier: String) -> Bool {
        !exemptBundleIdentifiers.contains(bundleIdentifier)
    }

    /// `nil` for anything that couldn't be matched at runtime (no bundle identifier) or isn't allowed on the list.
    init?(bundleURL: URL) {
        guard let identifier = Bundle(url: bundleURL)?.bundleIdentifier, Self.canLock(bundleIdentifier: identifier) else {
            return nil
        }
        self.init(bundleIdentifier: identifier, name: Self.displayName(for: bundleURL), path: bundleURL.path)
    }

    /// The Finder's own name for the bundle — localized, and without the extension it may or may not be showing.
    static func displayName(for bundleURL: URL) -> String {
        let name = FileManager.default.displayName(atPath: bundleURL.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    /// Falls back to wherever Launch Services says the app lives now, so a moved or updated app keeps its icon.
    /// Symlinks are resolved first: some system apps (Safari) sit behind one in /Applications, and the icon for a
    /// symlink comes back with an alias arrow drawn on it.
    var icon: NSImage {
        let workspace = NSWorkspace.shared
        let pickedURL = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        if FileManager.default.fileExists(atPath: pickedURL.path) {
            return workspace.icon(forFile: pickedURL.path)
        }
        if let currentURL = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return workspace.icon(forFile: currentURL.resolvingSymlinksInPath().path)
        }
        return workspace.icon(for: .application)
    }
}
