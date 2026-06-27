//
//  DockManager.swift
//  Available Software
//
//  Created by Gil Burns on 6/1/26.
//

import Foundation

struct DockManager {
    /// Adds an application bundle to the macOS Dock's persistent apps list.
    /// Returns `true` if the entry was appended, `false` if it was already present
    /// or the operation could not complete.
    @discardableResult
    static func addApp(at appPath: String) -> Bool {
        let normalizedPath = (appPath as NSString).standardizingPath
        guard FileManager.default.fileExists(atPath: normalizedPath) else {
            NSLog("DockManager: app not found at %@", normalizedPath)
            return false
        }

        let defaults = UserDefaults(suiteName: "com.apple.dock")
        guard var persistentApps = defaults?.array(forKey: "persistent-apps") as? [[String: Any]] else {
            NSLog("DockManager: failed to read persistent-apps from com.apple.dock")
            return false
        }

        // Avoid duplicates
        for entry in persistentApps {
            if let tileData = entry["tile-data"] as? [String: Any],
               let fileData = tileData["file-data"] as? [String: Any],
               let existingURL = fileData["_CFURLString"] as? String,
               let resolved = URL(string: existingURL) {
                let existing = (resolved.path as NSString).standardizingPath
                if existing == normalizedPath {
                    NSLog("DockManager: %@ is already in the Dock", normalizedPath)
                    return false
                }
            }
        }

        let fileURL = URL(fileURLWithPath: normalizedPath, isDirectory: true)
        let displayName = fileURL.deletingPathExtension().lastPathComponent

        let newEntry: [String: Any] = [
            "tile-type": "file-tile",
            "tile-data": [
                "file-label": displayName,
                "file-type": 41,
                "file-data": [
                    "_CFURLString": fileURL.absoluteString,
                    "_CFURLStringType": 15
                ]
            ]
        ]

        persistentApps.append(newEntry)
        defaults?.set(persistentApps, forKey: "persistent-apps")
        defaults?.synchronize()

        let killCfprefsd = Process()
        killCfprefsd.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killCfprefsd.arguments = ["cfprefsd"]
        do {
            try killCfprefsd.run()
            killCfprefsd.waitUntilExit()
        } catch {
            NSLog("Failed to launch killall cfprefsd: \(error)")
        }

        let killDock = Process()
        killDock.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killDock.arguments = ["Dock"]
        try? killDock.run()
        
        NSLog("DockManager: added %@ to Dock", normalizedPath)
        return true
    }
}
