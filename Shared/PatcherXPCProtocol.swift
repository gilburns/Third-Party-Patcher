//
//  PatcherXPCProtocol.swift
//
//  Shared XPC protocol between patcherscheduler (server) and PatcherMenu (client).
//  Add to both targets via target membership in Xcode.
//

import Foundation

@objc protocol PatcherXPCProtocol {
    /// Trigger a scheduler phase immediately, bypassing normal cadence.
    /// - Parameters:
    ///   - phase: One of "scan", "check", "stage", "apply"
    ///   - reply: Called with (true, "queued") on success, or (false, reason) on failure.
    ///            Called before the phase runs — use the ViewModel refresh to observe results.
    func triggerPhase(_ phase: String, reply: @escaping (Bool, String) -> Void)

    /// Install a single Installomator label via `patcher ensure <label>`.
    /// - Parameters:
    ///   - label: A valid Installomator label name (e.g. "microsoftword")
    ///   - reply: Called with (true, "installing") immediately; watch activeLabel via the
    ///            active_phase.json directory watcher for live progress.
    func installLabel(_ label: String, reply: @escaping (Bool, String) -> Void)

    /// Apply or remove a custom Finder icon on an app bundle (requires root — handled by daemon).
    /// - Parameters:
    ///   - iconPath: Absolute path to a PNG or ICNS file, or nil to restore the built-in icon.
    ///   - bundlePath: Absolute path to the .app bundle to modify.
    ///   - reply: Called with (true, "ok") on success, or (false, reason) on failure.
    func setAppIcon(iconPath: String?, bundlePath: String, reply: @escaping (Bool, String) -> Void)
}
