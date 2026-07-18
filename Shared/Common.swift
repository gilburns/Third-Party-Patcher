//
//  Common.swift
//  Third Party Patcher
//
//  Created by Gil Burns on 6/14/26.
//

import Foundation
import SwiftUI


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


// MARK: - Color from brand string

/// Converts a brand color string to a 6-digit uppercase hex string (no "#") for
/// use in SwiftDialog markdown color attributes.
/// - Named colors map to their approximate macOS system color values (light mode).
/// - Hex input ("RRGGBB" or "#RRGGBB", or 3-digit shorthand) is normalised to 6 digits.
/// - Unrecognised values fall back to "007AFF" (system blue).
func brandColorHex(_ brandString: String) -> String {
    let s = brandString.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") {
        var hex = String(s.dropFirst())
        if hex.count == 3 {
            hex = hex.flatMap { ["\($0)", "\($0)"] }.joined()
        }
        if hex.count == 6 { return hex.uppercased() }
        return "007AFF"
    }
    // 6-digit hex supplied without "#"
    if s.count == 6, let _ = UInt64(s, radix: 16) {
        return s.uppercased()
    }
    switch s.lowercased() {
    case "black":        return "000000"
    case "blue":         return "007AFF"
    case "brown":        return "A2845E"
    case "cyan":         return "32ADE6"
    case "gray", "grey": return "8E8E93"
    case "green":        return "34C759"
    case "indigo":       return "5856D6"
    case "mint":         return "00C7BE"
    case "orange":       return "FF9500"
    case "pink":         return "FF2D55"
    case "purple":       return "AF52DE"
    case "red":          return "FF3B30"
    case "teal":         return "30B0C7"
    case "white":        return "FFFFFF"
    case "yellow":       return "FFCC00"
    default:             return "007AFF"
    }
}

extension Color {
    /// Resolves a brand color string to a SwiftUI Color.
    /// Accepts named system colors ("blue", "white", etc.) or hex strings ("#00A4C7").
    /// Falls back to .accentColor for unrecognised values.
    init(brandString: String) {
        let s = brandString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") {
            var hex = String(s.dropFirst())
            if hex.count == 3 {
                hex = hex.flatMap { ["\($0)", "\($0)"] }.joined()
            }
            if hex.count == 6, let value = UInt64(hex, radix: 16) {
                self = Color(
                    red:   Double((value >> 16) & 0xFF) / 255,
                    green: Double((value >>  8) & 0xFF) / 255,
                    blue:  Double( value        & 0xFF) / 255
                )
                return
            }
            self = .accentColor
            return
        }
        switch s.lowercased() {
        case "black":        self = .black
        case "blue":         self = .blue
        case "brown":        self = .brown
        case "cyan":         self = .cyan
        case "gray", "grey": self = .gray
        case "green":        self = .green
        case "indigo":       self = .indigo
        case "mint":         self = .mint
        case "orange":       self = .orange
        case "pink":         self = .pink
        case "purple":       self = .purple
        case "red":          self = .red
        case "teal":         self = .teal
        case "white":        self = .white
        case "yellow":       self = .yellow
        default:             self = .accentColor
        }
    }
}
