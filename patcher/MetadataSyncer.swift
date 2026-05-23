//
//  MetadataSyncer.swift
//  patcher
//
//  Created by Gil Burns on 5/18/26.
//

import Foundation

// MARK: - Metadata repo sync

/// Downloads the Installomator-Metadata GitHub archive and extracts it to
/// AppConstants.installomatorMetadataFolderURL, atomically replacing any existing content.
func syncMetadataRepo(prefs: Preferences) {
    let account = prefs.installomatorGitHubMetadataAccount
    let repo    = prefs.installomatorGitHubMetadataRepo
    let branch  = prefs.installomatorGitHubMetadataBranch
    let destURL = AppConstants.installomatorMetadataFolderURL
    let fm      = FileManager.default

    Logger.log("ℹ️ MetadataSync: syncing \(account)/\(repo) @ \(branch)…")

    let tarballString = "https://github.com/\(account)/\(repo)/archive/refs/heads/\(branch).tar.gz"
    guard let tarballURL = URL(string: tarballString) else {
        Logger.log("❌ MetadataSync: invalid tarball URL.")
        return
    }

    let tempDir    = AppConstants.patcherTempFolderURL
    let tarFile    = tempDir.appendingPathComponent("metadata.tar.gz")
    let extractDir = tempDir.appendingPathComponent("metadata_extract")
    let backupDir  = tempDir.appendingPathComponent("metadata_backup")

    for url in [tarFile, extractDir, backupDir] { try? fm.removeItem(at: url) }

    // ── Download ────────────────────────────────────────────────────────────
    Logger.log("ℹ️ MetadataSync: downloading \(tarballString)…")
    let dlExit = runMetaProcess("/usr/bin/curl", [
        "--silent", "--fail", "--location",
        "--output", tarFile.path,
        tarballURL.absoluteString
    ])
    guard dlExit == 0, fm.fileExists(atPath: tarFile.path) else {
        Logger.log("❌ MetadataSync: download failed (exit \(dlExit)).")
        return
    }

    // ── Extract ─────────────────────────────────────────────────────────────
    do { try fm.createDirectory(at: extractDir, withIntermediateDirectories: true) }
    catch {
        Logger.log("❌ MetadataSync: could not create extract dir: \(error)")
        return
    }

    // --strip-components=1 removes the top-level "{repo}-{branch}/" wrapper so
    // Icons/, Metadata/, etc. land directly inside extractDir.
    let tarExit = runMetaProcess("/usr/bin/tar", [
        "--extract", "--gzip",
        "--file", tarFile.path,
        "--directory", extractDir.path,
        "--strip-components=1"
    ])
    guard tarExit == 0 else {
        Logger.log("❌ MetadataSync: extraction failed (exit \(tarExit)).")
        try? fm.removeItem(at: tarFile)
        try? fm.removeItem(at: extractDir)
        return
    }

    // ── Atomic replacement ──────────────────────────────────────────────────
    do {
        if fm.fileExists(atPath: destURL.path) {
            try fm.moveItem(at: destURL, to: backupDir)
        }
        try fm.moveItem(at: extractDir, to: destURL)
    } catch {
        Logger.log("❌ MetadataSync: failed to install synced metadata: \(error)")
        // Restore the backup so the previous data is not lost.
        if fm.fileExists(atPath: backupDir.path), !fm.fileExists(atPath: destURL.path) {
            try? fm.moveItem(at: backupDir, to: destURL)
        }
        return
    }

    // ── Remove unneeded content ──────────────────────────────────────────────
    let scriptsDir = destURL.appendingPathComponent("Scripts")
    if fm.fileExists(atPath: scriptsDir.path) {
        try? fm.removeItem(at: scriptsDir)
        Logger.log("ℹ️ MetadataSync: removed Scripts directory.")
    }

    // ── Cleanup temp artifacts ───────────────────────────────────────────────
    try? fm.removeItem(at: tarFile)
    try? fm.removeItem(at: backupDir)

    Logger.log("✅ MetadataSync: \(account)/\(repo) @ \(branch) synced to \(destURL.path).")
}

@discardableResult
private func runMetaProcess(_ executable: String, _ args: [String]) -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: executable)
    p.arguments = args
    p.standardOutput = Pipe()
    p.standardError  = Pipe()
    try? p.run()
    p.waitUntilExit()
    return p.terminationStatus
}
