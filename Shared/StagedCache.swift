//
//  StagedCache.swift
//  patcher
//
//  Single definition of what "staged" means for a label's cache folder:
//  .../Patcher/Cache/<label>/
//
//  A cache folder holds:
//    metadata.json  — bookkeeping (appNewVersion, downloadURL, stagedTimestamp, throttle keys)
//    history.json   — LabelHistory event log
//    <installer>    — the staged download (any other file)
//
//  A label is staged only when the installer file exists AND metadata.json carries
//  stagedTimestamp. metadata.json can outlive the installer (broken-label skips,
//  ignored labels and the apply-failure threshold delete only the file), so never
//  treat metadata alone as proof that something is staged.
//

import Foundation

enum StagedCache {

    static let metadataFileName = "metadata.json"

    struct Entry {
        let label: String
        let file: URL
        let appNewVersion: String
        let downloadURL: String?
        let stagedDate: Date?
    }

    // MARK: Locations

    static func labelDirectory(for label: String) -> URL {
        AppConstants.patcherCacheFolderURL.appendingPathComponent(label)
    }

    /// All per-label directories in the cache folder.
    static func labelDirectories() -> [URL] {
        let fm = FileManager.default
        guard let urls = try? fm.contentsOfDirectory(
            at: AppConstants.patcherCacheFolderURL, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return [] }
        return urls.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    // MARK: Files

    /// True for metadata.json and history.json — files that are never a staged installer.
    static func isBookkeepingFile(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name == metadataFileName || name == LabelHistory.fileName
    }

    /// Every non-bookkeeping file in a label's cache directory.
    static func stagedFiles(in labelDir: URL) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(at: labelDir, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { !isBookkeepingFile($0) }
    }

    /// The staged installer in a label's cache directory, or nil if only bookkeeping files exist.
    /// This is raw file presence — what apply would install — regardless of metadata.
    static func stagedFile(in labelDir: URL) -> URL? {
        stagedFiles(in: labelDir).first
    }

    // MARK: Metadata

    static func metadata(in labelDir: URL) -> [String: Any]? {
        let url = labelDir.appendingPathComponent(metadataFileName)
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return json
    }

    // MARK: Staged entries

    /// The staged entry for a label directory: installer file present and metadata.json
    /// carrying stagedTimestamp. Returns nil if either is missing.
    static func entry(in labelDir: URL) -> Entry? {
        guard let file = stagedFile(in: labelDir),
              let meta = metadata(in: labelDir),
              let tsString = meta["stagedTimestamp"] as? String
        else { return nil }
        return Entry(
            label: labelDir.lastPathComponent,
            file: file,
            appNewVersion: meta["appNewVersion"] as? String ?? "",
            downloadURL: meta["downloadURL"] as? String,
            stagedDate: ISO8601DateFormatter().date(from: tsString)
        )
    }

    static func entry(for label: String) -> Entry? {
        entry(in: labelDirectory(for: label))
    }

    /// All staged entries in the cache.
    static func entries() -> [Entry] {
        labelDirectories().compactMap { entry(in: $0) }
    }

    /// True when this exact version and download URL is staged with its installer on disk.
    /// Used to skip re-downloading something that is already in the cache.
    static func isStaged(label: String, appNewVersion: String, downloadURL: String) -> Bool {
        guard let entry = entry(for: label) else { return false }
        return entry.appNewVersion == appNewVersion && entry.downloadURL == downloadURL
    }
}
