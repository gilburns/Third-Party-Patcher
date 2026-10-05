//
//  InstallomatorLabels.swift
//  patcher
//
//  Created by Gil Burns on 1/5/25.
//

import Foundation

class InstallomatorLabels {
    static func compareInstallomatorVersion(completion: @escaping (Bool, String) -> Void) {
        let prefs = Preferences()
        let account = prefs.installomatorGitHubAccount
        let repo    = prefs.installomatorGitHubRepo
        let branch  = prefs.installomatorGitHubBranch

        // URL to fetch the latest version
        let installomatorCurrentVersionURL = URL(string: "https://raw.githubusercontent.com/\(account)/\(repo)/refs/heads/\(branch)/Installomator.sh")!

        let installomatorLocalVersionPath = AppConstants.installomatorVersionFileURL
            .path

        Task {
            do {
                // Fetch the latest version from the web
                let (data, response) = try await URLSession.shared.data(from: installomatorCurrentVersionURL)
                if let failure = gitHubFailureDescription(response: response, data: data) {
                    Logger.log("Failed to fetch \(installomatorCurrentVersionURL.absoluteString): \(failure)", logType: "Updates")
                    completion(false, "Failed to fetch Installomator version: \(failure)")
                    return
                }
                Logger.log("Decoding Installomator web content for current version.", logType: "Updates")
                guard let content = String(data: data, encoding: .utf8) else {
                    Logger.log("Failed to decode Installomator web content", logType: "Updates")
                    completion(false, "Failed to decode Installomator web content")
                    return
                }
                Logger.log("Successfully decoded Installomator web content", logType: "Updates")


                // Extract the VERSIONDATE= value using regex
                let regex = try NSRegularExpression(pattern: #"VERSIONDATE="([^"]*)"#)
                guard let match = regex.firstMatch(in: content, options: [], range: NSRange(content.startIndex..<content.endIndex, in: content)),
                      let versionRange = Range(match.range(at: 1), in: content) else {
                    Logger.log("Failed to extract VERSIONDATE", logType: "Updates")
                    completion(false, "Failed to extract VERSIONDATE")
                    return
                }

                let installomatorCurrentVersion = content[versionRange]
                Logger.log("Found Installomator current version: \(installomatorCurrentVersion)", logType: "Updates")
                
                // Get the local version
                let installomatorLocalVersion: String
                if FileManager.default.fileExists(atPath: installomatorLocalVersionPath) {
                    installomatorLocalVersion = try String(contentsOfFile: installomatorLocalVersionPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
                } else {
                    installomatorLocalVersion = "1990-01-01"
                }

                Logger.log("Found Installomator local version: \(installomatorLocalVersion)", logType: "Updates")

                // Convert dates to comparable formats
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd"

                guard let currentVersionDate = dateFormatter.date(from: String(installomatorCurrentVersion)),
                      let localVersionDate = dateFormatter.date(from: installomatorLocalVersion) else {
                    Logger.log("Failed to parse Installomator version dates", logType: "Updates")
                    completion(false, "Failed to parse Installomator version dates")
                    return
                }

                // Compare versions
                if currentVersionDate > localVersionDate {
                    Logger.verbose("New version available")
                    completion(false, "New Installomator version available: \(installomatorCurrentVersion)") // Online version is newer
                } else {
                    Logger.verbose("No new version available")
                    completion(true, "Installomator version is up to date: \(installomatorLocalVersion)") // Local version is up to date
                }
            } catch {
                Logger.log("Error comparing Installomator versions: \(error.localizedDescription)", logType: "Updates")
                completion(false, "Error: \(error.localizedDescription)")
            }
        }
    }

    static func installInstallomatorLabels(completion: @escaping (Bool, String) -> Void) {
        let prefs = Preferences()
        let account = prefs.installomatorGitHubAccount
        let repo    = prefs.installomatorGitHubRepo
        let branch  = prefs.installomatorGitHubBranch

        let tempDir = AppConstants.patcherTempFolderURL
            .appendingPathComponent("\(UUID().uuidString)")
        let extractDir = tempDir.appendingPathComponent("extract")

        // Branch archive from github.com (redirects to codeload). Avoids the
        // api.github.com branch lookup, whose unauthenticated limit of 60 requests/hour
        // is shared by every device behind the same public IP.
        let archiveString = "https://github.com/\(account)/\(repo)/archive/refs/heads/\(branch).tar.gz"
        guard let archiveURL = URL(string: archiveString) else {
            completion(false, "Invalid Installomator archive URL: \(archiveString)")
            return
        }

        do {
            try FileManager.default.createDirectory(at: extractDir, withIntermediateDirectories: true)
        } catch {
            Logger.log("Failed to create temp directory: \(error.localizedDescription)", logType: "Updates")
            completion(false, "Error: \(error.localizedDescription)")
            return
        }

        Task {
            defer { try? FileManager.default.removeItem(at: tempDir) }
            do {
                // Download the tar.gz
                let (tarGzData, response) = try await URLSession.shared.data(from: archiveURL)
                if let failure = gitHubFailureDescription(response: response, data: tarGzData) {
                    Logger.log("Failed to download \(archiveString): \(failure)", logType: "Updates")
                    completion(false, "Failed to download Installomator labels: \(failure)")
                    return
                }
                let installomatorTarGz = tempDir.appendingPathComponent("Installomator.tar.gz")
                try tarGzData.write(to: installomatorTarGz)

                // Extract the tar.gz. --strip-components=1 removes the top-level
                // "{repo}-{branch}/" wrapper so fragments/ lands directly in extractDir.
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
                process.arguments = ["-xzf", installomatorTarGz.path, "-C", extractDir.path, "--strip-components=1"]
                try process.run()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    completion(false, "Failed to extract Installomator archive (tar exit \(process.terminationStatus))")
                    return
                }

                // Copy the labels to destination
                let sourceDirectory = extractDir
                    .appendingPathComponent("fragments")
                    .appendingPathComponent("labels")
                guard FileManager.default.fileExists(atPath: sourceDirectory.path) else {
                    completion(false, "Installomator archive has no fragments/labels folder")
                    return
                }

                let destinationDirectory = AppConstants.installomatorLabelsFolderURL
                    .path

                try FileManager.default.createDirectory(atPath: destinationDirectory, withIntermediateDirectories: true, attributes: nil)
                if FileManager.default.fileExists(atPath: destinationDirectory) {
                    try FileManager.default.removeItem(atPath: destinationDirectory)
                }
                try FileManager.default.copyItem(atPath: sourceDirectory.path, toPath: destinationDirectory)

                // Get the Installomator.sh version
                let installomatorShPath = extractDir.appendingPathComponent("Installomator.sh")
                let versionContent: String
                if FileManager.default.fileExists(atPath: installomatorShPath.path) {
                    let shContent = try String(contentsOf: installomatorShPath, encoding: .utf8)
                    let regex = try NSRegularExpression(pattern: #"VERSIONDATE="([^"]*)"#)
                    if let match = regex.firstMatch(in: shContent, options: [], range: NSRange(shContent.startIndex..<shContent.endIndex, in: shContent)),
                       let versionRange = Range(match.range(at: 1), in: shContent) {
                        versionContent = String(shContent[versionRange])
                    } else {
                        versionContent = "1990-01-01"
                    }
                } else {
                    versionContent = "1990-01-01"
                }

                // Save version to Version.txt
                let versionFilePath = AppConstants.installomatorVersionFileURL
                    .path

                try versionContent.write(toFile: versionFilePath, atomically: true, encoding: .utf8)

                completion(true, "Labels successfully updated to version \(versionContent)")
            } catch {
                Logger.log("Error installing labels: \(error.localizedDescription)", logType: "Updates")
                completion(false, "Error: \(error.localizedDescription)")
            }
        }
    }
}
