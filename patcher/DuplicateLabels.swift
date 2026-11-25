//
//  DuplicateLabels.swift
//  patcher
//
//  The hosted list of duplicate Installomator labels (IgnoreDuplicateLabels).
//

import Foundation

/// Groups of Installomator labels that manage the same app, from the hosted
/// `LabelLists/duplicate-labels.json`. With `IgnoreDuplicateLabels` on, each group keeps
/// one label (its preferred label, or the members listed in `RequiredLabels`) and the
/// other members are ignored.
///
/// The list is downloaded from `DuplicateLabelsURL`; when that fails, the last
/// downloaded copy is used, and failing that the copy built into patcher. So a Mac that
/// has never reached the server still starts with the same groups.
enum DuplicateLabels {

    struct Group: Equatable {
        let id:        String
        let preferred: String
        let members:   [String]
    }

    struct Selection: Equatable {
        /// Labels to add to the ignored patterns.
        var ignored: [String] = []
        /// One log line per group that didn't simply keep its preferred label.
        var notes:   [String] = []
    }

    /// Loaded on first use (once per process).
    static let groups: [Group] = load()

    // MARK: - Selection

    /// The labels to ignore so that each group keeps one label.
    ///
    /// - Only members present in `allLabels` count; a group with fewer than two of them
    ///   has nothing to collapse.
    /// - Required members replace the preferred label. Every required member is kept:
    ///   requiring two members of a group is an explicit choice.
    /// - The preferred label follows `PreferPkgLabels` when the group also has its pkg
    ///   or non-pkg counterpart (e.g. `firefoxpkg` becomes `firefox` when it's false).
    /// - A group whose preferred label isn't available is left alone rather than ignoring
    ///   every member.
    static func selection(groups: [Group], allLabels: Set<String>, required: Set<String>,
                          preferPkgLabels: Bool) -> Selection {
        var result = Selection()
        for group in groups {
            let present = group.members.filter(allLabels.contains)
            guard present.count > 1 else { continue }

            let keep: [String]
            let requiredMembers = present.filter(required.contains)
            if !requiredMembers.isEmpty {
                keep = requiredMembers
                if !requiredMembers.contains(group.preferred) {
                    result.notes.append("⭐ \(group.id): required \(requiredMembers.joined(separator: ", ")) replaces preferred \(group.preferred)")
                }
            } else {
                let preferred = pkgAdjusted(group.preferred, present: Set(present), preferPkgLabels: preferPkgLabels)
                guard present.contains(preferred) else {
                    result.notes.append("⚠️ \(group.id): preferred label \(preferred) isn't available — group left as is")
                    continue
                }
                if preferred != group.preferred {
                    result.notes.append("📦 \(group.id): keeping \(preferred) instead of \(group.preferred) (PreferPkgLabels)")
                }
                keep = [preferred]
            }
            result.ignored.append(contentsOf: present.filter { !keep.contains($0) })
        }
        return result
    }

    private static func pkgAdjusted(_ label: String, present: Set<String>, preferPkgLabels: Bool) -> String {
        let suffix = "pkg"
        if preferPkgLabels {
            let pkg = label + suffix
            return present.contains(pkg) ? pkg : label
        }
        guard label.count > suffix.count, label.hasSuffix(suffix) else { return label }
        let base = String(label.dropLast(suffix.count))
        return present.contains(base) ? base : label
    }

    // MARK: - Parsing

    /// Groups from a `duplicate-labels.json` document, or nil when it isn't a schema 1
    /// document. Malformed groups (no id, preferred not a member) are skipped.
    static func parse(_ data: Data) -> [Group]? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["schemaVersion"] as? Int == 1,
              let items = object["groups"] as? [[String: Any]] else { return nil }
        return items.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty,
                  let preferred = item["preferred"] as? String,
                  let members = item["members"] as? [String],
                  members.contains(preferred) else { return nil }
            return Group(id: id, preferred: preferred, members: members)
        }
    }

    // MARK: - Loading

    private static let download = CachedDownload(
        what: "the duplicate label list",
        cacheURL: AppConstants.patcherConfigFolderURL.appendingPathComponent("duplicate_labels.json"),
        cacheMetaURL: AppConstants.patcherConfigFolderURL.appendingPathComponent("duplicate_labels_meta.plist"),
        maxCacheAge: nil)   // the list changes slowly; an old copy beats none

    private static func load() -> [Group] {
        let urlString = Preferences().duplicateLabelsURL
        if let url = URL(string: urlString), url.scheme?.lowercased() == "https" {
            if let data = download.fetch(url: url) {
                if let groups = parse(data) {
                    Logger.log("🧩 Duplicate label list loaded: \(groups.count) groups")
                    return groups
                }
                Logger.log("⚠️ The duplicate label list at \(urlString) could not be parsed")
                download.discardCache()
            }
        } else {
            Logger.log("⚠️ DuplicateLabelsURL is not a valid https URL")
        }
        let groups = parse(Data(DuplicateLabelsSnapshot.json.utf8)) ?? []
        Logger.log("🧩 Using the built-in duplicate label list: \(groups.count) groups")
        return groups
    }
}
