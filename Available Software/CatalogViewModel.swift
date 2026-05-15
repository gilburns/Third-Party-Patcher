//
//  CatalogViewModel.swift
//  Available Software
//
//  Created by Gil Burns on 4/24/26.
//

import Foundation
import Combine

@MainActor
final class CatalogViewModel: ObservableObject {

    @Published var items: [CatalogItem] = []

    private var metadataBase    = ""
    private var iconBase        = ""
    private var detectedLangCode = "en"

    // In-memory cache so reopening the window doesn't re-fetch everything
    private var metadataCache: [String: RemoteMetadata] = [:]

    struct CatalogItem: Identifiable {
        let id: String              // Installomator label key
        var displayName: String
        var installedVersion: String?
        var description: String?
        var publisher: String?
        var homepage: String?
        var documentation: String?
        var privacy: String?
        var iconURL: URL?
        var keywords: [String] = []
        var category: String?
    }

    private struct RemoteMetadata {
        var appName: String?
        var description: String?
        var publisher: String?
        var homepage: String?
        var documentation: String?
        var privacy: String?
        var keywords: String?
        var category: String?
    }

    func loadItems(preferences: Preferences) {
        let preferred = Locale.preferredLanguages.first ?? "en"
        detectedLangCode = preferred.components(separatedBy: "-").first ?? "en"

        let rawBase = "https://raw.githubusercontent.com/"
            + "\(preferences.installomatorGitHubMetadataAccount)/"
            + "\(preferences.installomatorGitHubMetadataRepo)/"
            + "refs/heads/"
            + "\(preferences.installomatorGitHubMetadataBranch)/"

        metadataBase = rawBase + "Metadata/"
        iconBase     = rawBase + "Icons/"

        // Discard any label names that have no corresponding label file on disk.
        // This prevents stale or mistyped OptionalLabels entries from appearing in the grid.
        let validLabels = preferences.optionalLabels.filter { label in
            guard labelFileExists(label) else {
                NSLog("Available Software: label '%@' not found in label folders — skipping.", label)
                return false
            }
            return true
        }

        items = validLabels.map { label in
            // Prefer a local managed icon; fall back to the remote URL
            let localIconURL = AppConstants.managedIconsFolderURL.appendingPathComponent("\(label).png")
            let iconURL: URL? = FileManager.default.fileExists(atPath: localIconURL.path)
                ? localIconURL
                : URL(string: iconBase + "\(label).png")

            var item = CatalogItem(
                id: label,
                displayName: resolveDisplayName(for: label),
                installedVersion: installedVersion(for: label),
                iconURL: iconURL
            )
            // Apply already-cached metadata immediately (no flicker on reload)
            if let cached = metadataCache[label] { apply(cached, to: &item) }
            return item
        }
        // Fetch metadata only for labels not yet cached
        for label in validLabels where metadataCache[label] == nil {
            Task { await fetchMetadata(for: label) }
        }
    }

    // MARK: - Remote metadata fetch

    private func fetchMetadata(for label: String) async {
        // Local managed metadata overrides remote entirely
        if let localMeta = loadLocalMetadata(for: label) {
            metadataCache[label] = localMeta
            guard let idx = items.firstIndex(where: { $0.id == label }) else { return }
            apply(localMeta, to: &items[idx])
            return
        }

        // Try localized remote plist first (skipped when language is already English)
        var meta: RemoteMetadata?
        if detectedLangCode != "en" {
            meta = await fetchRemoteMetadata(metadataBase + "\(detectedLangCode)/\(label).plist")
        }
        // Fall back to base (English) remote plist
        if meta == nil {
            meta = await fetchRemoteMetadata(metadataBase + "\(label).plist")
        }
        guard let meta else { return }

        metadataCache[label] = meta
        guard let idx = items.firstIndex(where: { $0.id == label }) else { return }
        apply(meta, to: &items[idx])
    }

    private func loadLocalMetadata(for label: String) -> RemoteMetadata? {
        let base = AppConstants.managedMetadataFolderURL
        let candidates: [URL] = detectedLangCode == "en"
            ? [base.appendingPathComponent("\(label).plist")]
            : [base.appendingPathComponent("\(detectedLangCode)/\(label).plist"),
               base.appendingPathComponent("\(label).plist")]

        for url in candidates {
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = try? Data(contentsOf: url),
                  let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
            else { continue }
            return remoteMetadata(from: dict)
        }
        return nil
    }

    private func fetchRemoteMetadata(_ urlString: String) async -> RemoteMetadata? {
        guard let url = URL(string: urlString),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return remoteMetadata(from: dict)
    }

    private func remoteMetadata(from dict: [String: Any]) -> RemoteMetadata {
        RemoteMetadata(
            appName:       dict["AppName"]       as? String,
            description:   dict["Description"]   as? String,
            publisher:     dict["Publisher"]      as? String,
            homepage:      dict["Homepage"]       as? String,
            documentation: dict["Documentation"]  as? String,
            privacy:       dict["Privacy"]        as? String,
            keywords:      dict["Keywords"]       as? String,
            category:      dict["Category"]       as? String
        )
    }

    private func apply(_ meta: RemoteMetadata, to item: inout CatalogItem) {
        if let name = meta.appName, !name.isEmpty { item.displayName = name }
        item.description   = meta.description.flatMap    { $0.isEmpty ? nil : $0 }
        item.publisher     = meta.publisher.flatMap       { $0.isEmpty ? nil : $0 }
        item.homepage      = meta.homepage.flatMap        { $0.isEmpty ? nil : $0 }
        item.documentation = meta.documentation.flatMap   { $0.isEmpty ? nil : $0 }
        item.privacy       = meta.privacy.flatMap         { $0.isEmpty ? nil : $0 }
        item.keywords      = meta.keywords.map {
            $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } ?? []
        item.category      = meta.category.flatMap      { $0.isEmpty ? nil : $0 }
    }

    // MARK: - Local metadata resolution (displayName fallback)

    private func resolveDisplayName(for label: String) -> String {
        if let name = discoveredName(for: label)        { return name }
        if let name = parsedLabelName(for: label,
            in: AppConstants.installomatorLabelsFolderURL) { return name }
        if let name = parsedLabelName(for: label,
            in: AppConstants.managedLabelsFolderURL) { return name }
        return label.prefix(1).uppercased() + label.dropFirst()
    }

    private func discoveredName(for label: String) -> String? {
        plistValue("name", label: label) as? String
    }

    private func installedVersion(for label: String) -> String? {
        let url = AppConstants.patcherDiscoveredFolderURL.appendingPathComponent("\(label).plist")
        guard let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }

        // Package receipt check takes priority
        if let packageID = dict["packageID"] as? String, !packageID.isEmpty {
            return livePackageVersion(packageID: packageID)
        }

        // App bundle check in standard managed locations only (no mdfind)
        let appName: String
        if let name = dict["appName"] as? String, !name.isEmpty {
            appName = name
        } else if let name = dict["name"] as? String, !name.isEmpty {
            appName = name + ".app"
        } else {
            return nil
        }

        let versionKey = (dict["versionKey"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "CFBundleShortVersionString"

        return liveApplicationVersion(appName: appName, versionKey: versionKey)
    }

    private func livePackageVersion(packageID: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        process.arguments = ["--pkg-info-plist", packageID]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        guard (try? process.run()) != nil else { return nil }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let version = plist["pkg-version"] as? String,
              !version.isEmpty,
              !version.split(separator: ".").allSatisfy({ $0 == "0" })
        else { return nil }

        return version
    }

    private func liveApplicationVersion(appName: String, versionKey: String) -> String? {
        let fm = FileManager.default
        let searchPaths = ["/Applications/\(appName)", "/Applications/Utilities/\(appName)"]

        for appPath in searchPaths {
            guard fm.fileExists(atPath: appPath) else { continue }
            guard !fm.fileExists(atPath: "\(appPath)/Contents/_MASReceipt") else { continue }

            if let plistData = NSDictionary(contentsOfFile: "\(appPath)/Contents/Info.plist"),
               let version = plistData[versionKey] as? String, !version.isEmpty {
                return version
            }
        }
        return nil
    }

    private func plistValue(_ key: String, label: String) -> Any? {
        let url = AppConstants.patcherDiscoveredFolderURL.appendingPathComponent("\(label).plist")
        guard let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return nil }
        return dict[key]
    }

    /// Returns true if a label file exists in either the Installomator or managed labels folder.
    private func labelFileExists(_ label: String) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: AppConstants.installomatorLabelsFolderURL.appendingPathComponent("\(label).sh").path)
            || fm.fileExists(atPath: AppConstants.managedLabelsFolderURL.appendingPathComponent("\(label).sh").path)
    }

    private func parsedLabelName(for label: String, in folder: URL) -> String? {
        let url = folder.appendingPathComponent(label)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let pattern = #"(?m)^\s*name\s*=\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: content,
                                           range: NSRange(content.startIndex..., in: content)),
              let range = Range(match.range(at: 1), in: content)
        else { return nil }
        return String(content[range])
    }
}
