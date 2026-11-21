//
//  DialogAppearance.swift
//  patcher
//
//  Icon choices shared by every window presenter. Icon specs use swiftDialog's syntax
//  (file path, URL, or "SF=symbol,…"), which PatcherNotifier's windows also accept, so
//  DialogIcon / OverlayIcon values in deployed profiles keep working.
//

import AppKit
import Foundation

/// Returns the main icon spec for patcher's windows.
/// Uses the DialogIcon preference when set; otherwise tries to compose a
/// hardware-accurate computer icon. Falls back to an SF symbol string.
func resolveDialogIcon(prefs: Preferences) -> String {
    let explicit = prefs.dialogIcon
    if !explicit.isEmpty { return explicit }
    if let composed = composedComputerIcon() { return composed }
    return hasBattery
        ? "SF=laptopcomputer.and.arrow.down,weight=regular,palette=gray,red"
        : "SF=desktopcomputer.and.arrow.down,weight=regular,palette=gray,red"
}

/// Composes a PNG icon from the system's hardware-accurate computer image
/// (NSImage.computerName — MacBook, iMac, Mac mini, etc.) with a red
/// download-arrow SF Symbol overlaid at the top center.
/// The result is cached in the patcher config folder so it is only rendered once.
func composedComputerIcon() -> String? {
    let iconURL = AppConstants.patcherConfigFolderURL.appendingPathComponent("dialog_icon.png")

    if FileManager.default.fileExists(atPath: iconURL.path) {
        return iconURL.path
    }

    let px = 512
    let sz = CGFloat(px)

    guard let computerImage = NSImage(named: NSImage.computerName),
          let bitmapRep = NSBitmapImageRep(
              bitmapDataPlanes: nil,
              pixelsWide: px, pixelsHigh: px,
              bitsPerSample: 8, samplesPerPixel: 4,
              hasAlpha: true, isPlanar: false,
              colorSpaceName: .deviceRGB,
              bytesPerRow: 0, bitsPerPixel: 0),
          let ctx = NSGraphicsContext(bitmapImageRep: bitmapRep)
    else { return nil }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx

    // Hardware-accurate computer image fills the canvas
    computerImage.draw(in: NSRect(x: 0, y: 0, width: sz, height: sz),
                       from: .zero, operation: .copy, fraction: 1.0)

    // Red download arrow centered at the top — plain arrow, no circle background
    let badgeSz   = sz * 0.40
    let badgeRect = NSRect(x: (sz - badgeSz) / 2, y: sz - badgeSz * 1.5, width: badgeSz, height: badgeSz)
    let symConfig = NSImage.SymbolConfiguration(pointSize: badgeSz * 0.5, weight: .medium)
        .applying(NSImage.SymbolConfiguration(hierarchicalColor: .systemRed))
    if let arrow = NSImage(systemSymbolName: "arrow.down",
                           accessibilityDescription: nil)?
        .withSymbolConfiguration(symConfig) {
        arrow.draw(in: badgeRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }

    NSGraphicsContext.restoreGraphicsState()

    guard let pngData = bitmapRep.representation(using: .png, properties: [:]) else { return nil }

    do {
        try pngData.write(to: iconURL)
        Logger.log("ℹ️ Composed dialog icon saved to \(iconURL.path)")
        return iconURL.path
    } catch {
        Logger.log("⚠️ Failed to save composed dialog icon: \(error)")
        return nil
    }
}

/// Returns the overlay icon path when UseOverlayIcon is enabled, or nil.
/// Uses the OverlayIcon preference when set; otherwise probes for known MDM
/// agent apps in the same priority order as App-Auto-Patch.
func resolveOverlayIcon(prefs: Preferences) -> String? {
    guard prefs.useOverlayIcon else { return nil }

    let explicit = prefs.overlayIcon
    if !explicit.isEmpty { return explicit }

    let fm = FileManager.default

    // Jamf — read app path from the Jamf plist (covers non-standard install locations)
    for plistKey in ["self_service_app_path", "self_service_plus_path"] {
        if let appPath = jamfPlistValue(key: plistKey) {
            let icns = appPath + "/Contents/Resources/AppIcon.icns"
            if fm.fileExists(atPath: icns) { return icns }
        }
    }

    // Known MDM / management agent paths, in priority order
    let candidates: [String] = [
        "/Library/Application Support/JAMF/Jamf.app/Contents/Resources/AppIcon.icns",
        "/Applications/Self Service.app/Contents/Resources/AppIcon.icns",
        "/Applications/Self-Service.app/Contents/Resources/AppIcon.icns",
        "/Library/Intune/Microsoft Intune Agent.app/Contents/Resources/AppIcon.icns",
        "/Applications/Company Portal.app/Contents/Resources/AppIcon.icns",
        "/Applications/Manager.app/Contents/Resources/AppIcon.icns",
        "/Library/Addigy/macmanage/MacManage.app/Contents/Resources/atom.icns",
        "/Applications/Workspace ONE Intelligent Hub.app/Contents/Resources/AppIcon.icns",
        "/Applications/Kandji Self Service.app/Contents/Resources/AppIcon.icns",
        "/usr/local/sbin/FileWave.app/Contents/Resources/fwGUI.app/Contents/Resources/kiosk.icns",
        "/System/Applications/App Store.app/Contents/Resources/AppIcon.icns",
        "/Applications/App Store.app/Contents/Resources/AppIcon.icns",
    ]
    return candidates.first { fm.fileExists(atPath: $0) }
}

/// Reads a string value from the Jamf plist, returning nil on any failure.
private func jamfPlistValue(key: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults")
    p.arguments = ["read", "/Library/Preferences/com.jamfsoftware.jamf.plist", key]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError  = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    // Read to EOF before waiting — waiting first can deadlock if the output fills the pipe.
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { return nil }
    let value = String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
    return value?.isEmpty == false ? value : nil
}
