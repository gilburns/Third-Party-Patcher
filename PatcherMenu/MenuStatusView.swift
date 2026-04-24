//
//  MenuStatusView.swift
//  PatcherMenu
//
//  Created by Gil Burns on 4/22/26.
//

import SwiftUI

struct MenuStatusView: View {
    @EnvironmentObject private var vm: PatcherMenuViewModel
    @State private var showingHelp = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            headerSection
            Divider()
            VStack(alignment: .leading, spacing: 12) {
                patchSection
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
            VStack(alignment: .leading, spacing: 2) {
                Text(vm.preferences.appTitle)
                    .font(.headline)
                Text("Refreshed \(vm.refreshedAgo)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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

    // MARK: - Patch status

    private var patchSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            MenuSectionHeader("Pending Updates")

            if vm.stagedPatches.isEmpty {
                Label("All apps up to date", systemImage: "checkmark.circle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)

                // Monthly mode: show upcoming patch day even when nothing is pending
                if vm.preferences.monthlyPatchingCadenceEnabled, let next = vm.nextPatchDay {
                    Text("Next patch day: \(next, format: .dateTime.weekday(.wide).month(.abbreviated).day())")
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
                deadlineSection
            }
        }
    }

    // MARK: - Deadline detail

    @ViewBuilder
    private var deadlineSection: some View {
        if vm.deadlineReference != nil {
            Divider().padding(.vertical, 2)
            VStack(alignment: .leading, spacing: 4) {

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
                    Text("Deferred \(vm.deferralCount) time\(vm.deferralCount == 1 ? "" : "s")")
                        .font(.caption)
                }
                .foregroundStyle(.secondary)

                // Next prompt
                if let next = vm.nextPromptDate {
                    HStack(spacing: 4) {
                        Image(systemName: "clock")
                            .frame(width: 14)
                        Text("Next prompt: \(next, format: .relative(presentation: .named, unitsStyle: .abbreviated))")
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
            activityRow("Scan",  date: vm.schedulerState?.lastScanDate)
            activityRow("Check", date: vm.schedulerState?.lastCheckDate)
            activityRow("Stage", date: vm.schedulerState?.lastStageDate)
            activityRow("Apply", date: vm.schedulerState?.lastApplyDate)
        }
    }

    private func activityRow(_ label: String, date: Date?) -> some View {
        HStack(spacing: 0) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .leading)
            Text(date.map { formatDate($0) } ?? "Never")
                .font(.caption)
                .foregroundStyle(date == nil ? .tertiary : .primary)
        }
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
            .buttonStyle(.plain)
            .foregroundStyle(.tint)

            Spacer()

            if vm.preferences.showQuitButton && !vm.preferences.showMenuBarApp {
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
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

private struct SupportInfoView: View {
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
        .frame(width: 250)
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
