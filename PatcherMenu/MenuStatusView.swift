//
//  MenuStatusView.swift
//  PatcherMenu
//
//  Created by Gil Burns on 4/22/26.
//

import SwiftUI

struct MenuStatusView: View {
    @EnvironmentObject private var vm: PatcherMenuViewModel
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var showingHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()
            actionSection
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                patchSection
                if !vm.detectedPatches.isEmpty {
                    Divider()
                    pendingDownloadsSection
                }
                
                deadlineSection
                
                if vm.preferences.showActivitySection {
                    Divider()
                    activitySection
                }
            }
            .padding(12)
            Divider()
            footerSection
        }
        .frame(width: 300)
    }
    

    // MARK: - Header

    private var headerSection: some View {
        HStack(alignment: .center) {
            HStack(spacing: 5) {
                HeaderIcon(preferences: vm.preferences, size: 48)
                    .padding(.top, -5)

                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.preferences.appTitle)
                        .font(.headline)
                    Text("Refreshed \(vm.refreshedAgo)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if vm.isLoading {
                ProgressView().scaleEffect(0.7).padding(.trailing, 4)
            }
            if vm.preferences.showHelpButton {
                Button {
                    showingHelp.toggle()
                } label: {
                    Image(systemName: "questionmark.circle")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .popover(isPresented: $showingHelp, arrowEdge: .bottom) {
                    SupportInfoView(preferences: vm.preferences)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
    
    private struct HeaderIcon: View {
        let preferences: Preferences
        let size: CGFloat

        init(preferences: Preferences, size: CGFloat = 48) {
            self.preferences = preferences
            self.size = size
        }

        var body: some View {
            ZStack(alignment: .bottomTrailing) {
                mainImage
                    .resizable()
                    .scaledToFit()
                    .frame(width: size, height: size)

                if preferences.useOverlayIcon, let overlay = Self.overlayImage(for: preferences) {
                    overlay
                        .resizable()
                        .scaledToFit()
                        .frame(width: size * 0.40, height: size * 0.40)
                        .offset(x: 4, y: 4)
                }
            }
            .frame(width: size + 4, height: size + 4)
        }

        private var mainImage: Image {
            let iconStr = preferences.dialogIcon

            if iconStr.isEmpty {
                let cached = AppConstants.patcherConfigFolderURL.appendingPathComponent("dialog_icon.png")
                if let img = NSImage(contentsOf: cached) { return Image(nsImage: img) }
                if let img = NSImage(named: NSImage.computerName) { return Image(nsImage: img) }
                return Image(systemName: "desktopcomputer")
            }
            if iconStr.hasPrefix("/") || iconStr.hasPrefix("~") {
                let path = (iconStr as NSString).expandingTildeInPath
                if let img = NSImage(contentsOfFile: path) { return Image(nsImage: img) }
                return Image(systemName: "desktopcomputer")
            }
            if iconStr.hasPrefix("SF=") {
                let symbolName = String(iconStr.dropFirst(3).split(separator: ",").first ?? "desktopcomputer")
                return Image(systemName: symbolName)
            }
            return Image(systemName: iconStr)
        }

        static func overlayImage(for preferences: Preferences) -> Image? {
            let explicit = preferences.overlayIcon
            if !explicit.isEmpty {
                let path = (explicit as NSString).expandingTildeInPath
                if let img = NSImage(contentsOfFile: path) { return Image(nsImage: img) }
            }
            let candidates = [
                "/Library/Application Support/JAMF/Jamf.app/Contents/Resources/AppIcon.icns",
                "/Applications/Self Service.app/Contents/Resources/AppIcon.icns",
                "/Applications/Self-Service.app/Contents/Resources/AppIcon.icns",
                "/Applications/Manager.app/Contents/Resources/AppIcon.icns",
                "/Library/Addigy/macmanage/MacManage.app/Contents/Resources/atom.icns",
                "/Library/Intune/Microsoft Intune Agent.app/Contents/Resources/AppIcon.icns",
                "/Applications/Company Portal.app/Contents/Resources/AppIcon.icns",
                "/Applications/Workspace ONE Intelligent Hub.app/Contents/Resources/AppIcon.icns",
                "/Applications/Kandji Self Service.app/Contents/Resources/AppIcon.icns",
                "/usr/local/sbin/FileWave.app/Contents/Resources/fwGUI.app/Contents/Resources/kiosk.icns",
                "/System/Applications/App Store.app/Contents/Resources/AppIcon.icns",
                "/Applications/App Store.app/Contents/Resources/AppIcon.icns",
            ]
            return candidates.first(where: { FileManager.default.fileExists(atPath: $0) })
                .flatMap { NSImage(contentsOfFile: $0) }
                .map { Image(nsImage: $0) }
        }
    }


    // MARK: - Action section
    
    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            MenuSectionHeader("Actions")
            
            HStack {
                Menu {
                    Button("Apply pending updates") {
                        vm.triggerPhase("apply")
                        dismissWindow()
                    }
                        .disabled(!vm.hasPendingPatches)
                        .help(vm.hasPendingPatches
                              ? "Apply any staged pending updates"
                              : "No staged updates — run Download first")
                    if vm.preferences.showMenuDownloadAction
                        || vm.preferences.showMenuCheckAction
                        || vm.preferences.showMenuScanAction {
                        Divider()
                    }
                    if vm.preferences.showMenuDownloadAction {
                        Button("Download new Updates") { vm.triggerPhase("stage") }
                            .disabled(!vm.hasDetectedUpdates)
                            .help(vm.hasDetectedUpdates
                                  ? "Download and verify any available updates"
                                  : "No new updates detected — run Check or Scan first")
                    }
                    if vm.preferences.showMenuCheckAction {
                        Button("Check for Updates") {
                            vm.triggerPhase("check")
                            dismissWindow()
                        }
                            .help("Check for any available updates for previously discovered apps")
                    }
                    if vm.preferences.showMenuScanAction {
                        Button("Full Discovery Scan") { vm.triggerPhase("scan") }
                            .help("Runs a full discovery scan for installed applications. This can take a while.")
                    }
                } label: {
                    Label("Run Now", systemImage: "play.circle")
                        .font(.caption)
                }
                .menuStyle(.button)
                .buttonStyle(.accessoryBar)
                .foregroundStyle(.foreground)
                .controlSize(.small)
                .help("Run actions…")

                Spacer()

                if !vm.preferences.optionalLabels.isEmpty {
                    Button {
                        let config = NSWorkspace.OpenConfiguration()
                        config.activates = true
                        if let url = NSWorkspace.shared.urlForApplication(
                            withBundleIdentifier: AppConstants.availableSoftwareBundleID
                        ) {
                            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
                        } else {
                            NSWorkspace.shared.openApplication(
                                at: AppConstants.availableSoftwareAppURL,
                                configuration: config, completionHandler: nil
                            )
                        }
                        dismissWindow()
                    } label: {
                        Label("Available Software", systemImage: "app.gift")
                            .font(.caption)
                    }
                    .menuStyle(.button)
                    .buttonStyle(.accessoryBar)
                    .foregroundStyle(.foreground)
                    .controlSize(.small)
                    .help("Open Available Software…")
                } else {
                    Spacer()
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }


    // MARK: - Patch status

    private var patchSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                MenuSectionHeader("Pending Updates")
                Spacer()
                Text("Count: \(vm.stagedPatches.count)")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 2)
            }

            if vm.stagedPatches.isEmpty {
                Label("All apps up to date", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)

                // Monthly mode: show upcoming patch day even when nothing is pending
                if vm.preferences.monthlyPatchingCadenceEnabled, let next = vm.nextPatchDay {
                    Text("Next patch cycle: \(next, format: .dateTime.weekday(.wide).month(.abbreviated).day())")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.top, 2)
                }
            } else {
                ForEach(vm.stagedPatches) { patch in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 6, height: 6)
                        Text(patch.displayName)
                            .font(.subheadline)
                        Spacer()
                        Text(patch.newVersion)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    // MARK: - Pending downloads

    private var pendingDownloadsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                MenuSectionHeader("Pending Downloads")
                Spacer()
                Text("Count: \(vm.detectedPatches.count)")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 2)
            }
            ForEach(vm.detectedPatches) { patch in
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color.blue)
                        .frame(width: 6, height: 6)
                    Text(patch.displayName)
                        .font(.subheadline)
                    Spacer()
                    if let version = patch.availableVersion, !version.isEmpty {
                        Text(version)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    // MARK: - Deadline detail

    @ViewBuilder
    private var deadlineSection: some View {
        if vm.deadlineReference != nil {
            Divider().padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 4) {
                MenuSectionHeader("Deadline details")

                // Hard deadline
                if let deadline = vm.hardDeadlineDate, let days = vm.daysUntilHardDeadline {
                    HStack(spacing: 4) {
                        Image(systemName: "calendar.badge.exclamationmark")
                            .frame(width: 14)
                        if days <= 0 {
                            Text("Hard deadline: TODAY")
                                .font(.caption).fontWeight(.semibold)
                                .foregroundStyle(.red)
                        } else {
                            Text("Hard deadline: ")
                                .font(.caption)
                            + Text(deadline, format: .dateTime.month(.abbreviated).day())
                                .font(.caption)
                            + Text(" (in \(days)d)")
                                .font(.caption)
                                .foregroundStyle(deadlineColor(days: days))
                        }
                    }
                    .foregroundStyle(deadlineColor(days: days))
                }

                // Focus deadline
                if let focus = vm.focusDeadlineDate {
                    let focusDays = Calendar.current.dateComponents([.day], from: Date(), to: focus).day ?? 0
                    if focusDays > 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "moon.fill")
                                .frame(width: 14)
                            Text("Focus ignored after: ")
                                .font(.caption)
                            + Text(focus, format: .dateTime.month(.abbreviated).day())
                                .font(.caption)
                            + Text(" (in \(focusDays)d)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .foregroundStyle(.secondary)
                    }
                }

                // Deferral count
                HStack(spacing: 4) {
                    Image(systemName: "arrow.uturn.backward")
                        .frame(width: 14)
                    Text("Deferred \(vm.deferralCount) time\(vm.deferralCount == 1 ? "" : "s") (Includes auto-deferrals)")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)

                // Next prompt
                if let label = vm.nextPromptLabel {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .frame(width: 14)
                        Text("Next prompt: \(label)")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Activity

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 4) {
            MenuSectionHeader("Last Activity")
            activityRow("Apply", phase: "apply", date: vm.schedulerState?.lastApplyDate)
            activityRow("Stage", phase: "stage", date: vm.schedulerState?.lastStageDate)
            activityRow("Check", phase: "check", date: vm.schedulerState?.lastCheckDate)
            activityRow("Scan",  phase: "scan",  date: vm.schedulerState?.lastScanDate)
        }
    }

    private func activityRow(_ label: String, phase: String, date: Date?) -> some View {
        let isRunning = vm.activePhase == phase
        return HStack(spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
            if isRunning {
                Text("Running")
                    .font(.caption)
                    .foregroundStyle(.primary)
                ProgressView()
                    .scaleEffect(0.40)
                    .frame(width: 25, height: 6)
            } else {
                Text(date.map { formatDate($0) } ?? "Never")
                    .font(.caption)
                    .foregroundStyle(date == nil ? .tertiary : .primary)
            }
        }
        .animation(.default, value: isRunning)
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button {
                vm.refresh()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
                    .font(.caption)
            }
            .buttonStyle(.accessoryBar)
            .foregroundStyle(.foreground)

            Spacer()

            if vm.preferences.showQuitButton && !vm.preferences.showMenuBarApp {
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.accessoryBar)
                .font(.caption)
                .foregroundStyle(.foreground)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Helpers

    private func deadlineColor(days: Int) -> Color {
        if days <= 0 { return .red }
        if days <= 3 { return .orange }
        if days <= 7 { return Color(red: 0.8, green: 0.6, blue: 0) }
        return .secondary
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.doesRelativeDateFormatting = true
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Support info panel

struct SupportInfoView: View {
    let preferences: Preferences

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Get Help")
                .font(.headline)

            Divider()

            Text(preferences.supportTeamName)
                .font(.subheadline)
                .fontWeight(.medium)

            VStack(alignment: .leading, spacing: 6) {
                contactRow(
                    icon: "envelope.fill",
                    text: preferences.supportTeamEmail,
                    url: URL(string: "mailto:\(preferences.supportTeamEmail)")
                )

                if preferences.supportTeamPhone != "None" {
                    contactRow(icon: "phone.fill", text: preferences.supportTeamPhone, url: nil)
                }

                if preferences.supportTeamWebsite != "None" {
                    let raw = preferences.supportTeamWebsite
                    let urlStr = raw.hasPrefix("http") ? raw : "https://\(raw)"
                    contactRow(icon: "globe", text: raw, url: URL(string: urlStr))
                }
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    private func contactRow(icon: String, text: String, url: URL?) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .frame(width: 14)
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            if let url {
                Link(text, destination: url)
                    .font(.subheadline)
                    .lineLimit(2)
            } else {
                Text(text)
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .lineLimit(2)
            }
        }
    }
}

// MARK: - Section header

private struct MenuSectionHeader: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .font(.caption2)
            .fontWeight(.semibold)
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .padding(.bottom, 2)
    }
}
