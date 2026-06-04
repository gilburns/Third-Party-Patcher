//
//  AvailableSoftwareApp.swift
//  Available Software
//
//  Created by Gil Burns on 4/25/26.
//

import SwiftUI
import AppKit

@main
struct AvailableSoftwareApp: App {
    @StateObject private var viewModel = AvailableSoftwareViewModel()

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
        applyCustomIcon()
    }

    var body: some Scene {
        WindowGroup {
            CatalogView()
                .environmentObject(viewModel)
        }
        .defaultSize(width: 720, height: 560)
    }

    private func applyCustomIcon() {
        let prefs      = Preferences()
        let bundlePath = Bundle.main.bundlePath

        // Icon\r inside the bundle is the marker macOS writes when a Finder custom icon
        // is present. It is world-readable, so any user can detect it without privileges.
        let hasFinderIcon = FileManager.default.fileExists(
            atPath: bundlePath + "/Icon\r"
        )

        if let path = prefs.customAppIconPath, let image = NSImage(contentsOfFile: path) {
            // Dock / app switcher — in-process, works for any user.
            NSApplication.shared.applicationIconImage = image
            // Always ask the daemon to (re-)apply the Finder icon so that a changed
            // icon path is picked up on relaunch without any extra tracking.
            xpcSetAppIcon(iconPath: path, bundlePath: bundlePath)
        } else {
            NSApplication.shared.applicationIconImage = nil
            // Only round-trip to the daemon when there is actually something to remove.
            if hasFinderIcon {
                xpcSetAppIcon(iconPath: nil, bundlePath: bundlePath)
            }
        }
    }

    private func xpcSetAppIcon(iconPath: String?, bundlePath: String) {
        let conn = NSXPCConnection(machServiceName: AppConstants.patcherXPCServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: PatcherXPCProtocol.self)
        conn.resume()
        guard let proxy = conn.remoteObjectProxyWithErrorHandler({ error in
            NSLog("AvailableSoftware setAppIcon XPC error: %@", error.localizedDescription)
            conn.invalidate()
        }) as? PatcherXPCProtocol else {
            conn.invalidate()
            return
        }
        proxy.setAppIcon(iconPath: iconPath, bundlePath: bundlePath) { success, message in
            NSLog("AvailableSoftware setAppIcon: success=%d message=%@", success, message)
            conn.invalidate()
        }
    }
}
