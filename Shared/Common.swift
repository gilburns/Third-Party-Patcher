//
//  Common.swift
//  Third Party Patcher
//
//  Created by Gil Burns on 6/14/26.
//

import Foundation

/// Returns the local icon path for a given Installomator label.
/// Checks the synced metadata Icons folder first; falls back to the system
/// package icon when no label-specific icon exists on disk.
func resolveLabelIcon(label: String) -> String {
    // 1. Admin-managed icons (highest priority — intentional overrides).
    let managed = AppConstants.managedIconsFolderURL
        .appendingPathComponent("\(label).png")
    if FileManager.default.fileExists(atPath: managed.path) {
        return managed.path
    }
    // 2. Locally synced metadata repo.
    let iconURL = AppConstants.installomatorMetadataFolderURL
        .appendingPathComponent("Icons")
        .appendingPathComponent("\(label).png")
    if FileManager.default.fileExists(atPath: iconURL.path) {
        return iconURL.path
    }
    return "/System/Library/CoreServices/Installer.app/Contents/Resources/package.icns"
}


func resolveDisplayName(for label: String) -> String {
    let url = AppConstants.patcherDiscoveredFolderURL.appendingPathComponent("\(label).plist")
    if let data = try? Data(contentsOf: url),
       let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
       let name = dict["name"] as? String, !name.isEmpty {
        return name
    }
    return label.prefix(1).uppercased() + label.dropFirst()
}

func resolveIconURL(for label: String) -> URL? {
    let preferences = Preferences.init()
    // 1. Admin-managed icons (highest priority — intentional overrides).
    let managed = AppConstants.managedIconsFolderURL.appendingPathComponent("\(label).png")
    if FileManager.default.fileExists(atPath: managed.path) { return managed }
    // 2. Locally synced metadata repo (fast, works offline after first sync).
    let synced = AppConstants.installomatorMetadataFolderURL
        .appendingPathComponent("Icons")
        .appendingPathComponent("\(label).png")
    if FileManager.default.fileExists(atPath: synced.path) { return synced }
    // 3. Remote fallback (used before first sync or for labels with no local icon).
    let base = "https://raw.githubusercontent.com/"
        + "\(preferences.installomatorGitHubMetadataAccount)/"
        + "\(preferences.installomatorGitHubMetadataRepo)/"
        + "refs/heads/\(preferences.installomatorGitHubMetadataBranch)/Icons/"
    return URL(string: base + "\(label).png")
}
