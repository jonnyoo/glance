//
//  InstalledApps.swift
//  glance
//
//  Discovers installed applications on the system.
//

import Foundation
import AppKit

/// Represents an application discovered on the system.
public struct DiscoveredApp: Identifiable, Equatable {
    public var id: String { bundleID }
    public let bundleID: String
    public let name: String
    public let url: URL
    public let icon: NSImage
}

/// Utility for discovering installed applications.
public enum InstalledApps {
    /// Scans standard application directories to find installed .app bundles.
    public static func scanApps() -> [DiscoveredApp] {
        return discover()
    }

    public static func discover() -> [DiscoveredApp] {
        let fileManager = FileManager.default
        let searchPaths = [
            "/Applications",
            "/System/Applications",
            (NSHomeDirectory() as NSString).appendingPathComponent("Applications")
        ]
        
        var discovered = [DiscoveredApp]()
        var seenBundleIDs = Set<String>()
        
        for path in searchPaths {
            let url = URL(fileURLWithPath: path)
            // Enumerate up to depth 2 to catch apps in subfolders like Utilities
            if let enumerator = fileManager.enumerator(at: url,
                                                       includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                
                for case let fileURL as URL in enumerator {
                    // Check depth
                    let pathComponentsCount = fileURL.pathComponents.count
                    let basePathComponentsCount = url.pathComponents.count
                    let depth = pathComponentsCount - basePathComponentsCount
                    
                    if depth > 2 {
                        enumerator.skipDescendants()
                        continue
                    }
                    
                    if fileURL.pathExtension == "app" {
                        if let bundle = Bundle(url: fileURL),
                           let bundleID = bundle.bundleIdentifier {
                            
                            // Skip if already seen
                            if seenBundleIDs.contains(bundleID) { continue }
                            
                            // Skip background-only apps
                            let info = bundle.infoDictionary
                            let isBackgroundOnly = (info?["LSBackgroundOnly"] as? Bool) ?? (info?["LSBackgroundOnly"] as? String == "1")
                            let isUIElement = (info?["LSUIElement"] as? Bool) ?? (info?["LSUIElement"] as? String == "1")
                            
                            if !isBackgroundOnly && !isUIElement {
                                let name = (info?["CFBundleDisplayName"] as? String) ??
                                           (info?["CFBundleName"] as? String) ??
                                           fileURL.deletingPathExtension().lastPathComponent
                                
                                let icon = NSWorkspace.shared.icon(forFile: fileURL.path)
                                
                                let app = DiscoveredApp(bundleID: bundleID, name: name, url: fileURL, icon: icon)
                                discovered.append(app)
                                seenBundleIDs.insert(bundleID)
                            }
                        }
                        
                        // Don't search inside .app bundles
                        enumerator.skipDescendants()
                    }
                }
            }
        }
        
        // Sort by name
        return discovered.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
