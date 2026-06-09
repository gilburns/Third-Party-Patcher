//
//  CatalogView.swift
//  Available Software
//
//  Created by Gil Burns on 4/24/26.
//

import AppKit
import SwiftUI

// MARK: - Image cache

private final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, NSImage>()

    func image(for url: URL) -> NSImage? {
        cache.object(forKey: url.absoluteString as NSString)
    }

    func store(_ image: NSImage, for url: URL) {
        cache.setObject(image, forKey: url.absoluteString as NSString)
    }
}

private struct CachedAsyncImage<Content: View, Placeholder: View>: View {
    let url: URL?
    let content: (Image) -> Content
    let placeholder: () -> Placeholder

    @State private var nsImage: NSImage?

    init(url: URL?,
         @ViewBuilder content: @escaping (Image) -> Content,
         @ViewBuilder placeholder: @escaping () -> Placeholder) {
        self.url = url
        self.content = content
        self.placeholder = placeholder
        if let url, let cached = ImageCache.shared.image(for: url) {
            _nsImage = State(initialValue: cached)
        }
    }

    var body: some View {
        Group {
            if let nsImage {
                content(Image(nsImage: nsImage))
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url, nsImage == nil else { return }
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let img = NSImage(data: data) else { return }
            ImageCache.shared.store(img, for: url)
            nsImage = img
        }
    }
}

private func genericAppIcon() -> NSImage {
//    Bundle(path: "/System/Library/CoreServices/CoreTypes.bundle")?
//        .image(forResource: "GenericApplicationIcon")
//    ??
    NSImage(contentsOfFile:
        "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericApplicationIcon.icns")
    ?? NSImage(named: NSImage.applicationIconName)
    ?? NSImage()
}

struct CatalogView: View {
    @EnvironmentObject var vm: AvailableSoftwareViewModel
    @StateObject private var catalog = CatalogViewModel()
    @State private var showingHelp    = false
    @State private var searchText     = ""
    @State private var sortOrder      = SortOrder.arrayOrder
    @State private var filterMode     = FilterMode.all
    @State private var selectedItem: CatalogViewModel.CatalogItem? = nil
    @State private var selectedStagedPatch: AvailableSoftwareViewModel.StagedPatch? = nil
    @State private var selectedManagedApp: AvailableSoftwareViewModel.ManagedApp? = nil
    @State private var selectedHistoryLabel: String? = nil
    @State private var columnVisibility      = NavigationSplitViewVisibility.all
    @State private var categoriesExpanded    = false

    enum SortOrder  { case arrayOrder, alphabetical }
    enum FilterMode: Hashable {
        case all, installed, notInstalled, category(String)
        case pendingUpdates, pendingDownloads, managedSoftware, updateHistory, about
    }

    private var filteredItems: [CatalogViewModel.CatalogItem] {
        var result = catalog.items

        switch filterMode {
        case .all:               break
        case .installed:         result = result.filter { $0.installedVersion != nil }
        case .notInstalled:      result = result.filter { $0.installedVersion == nil }
        case .category(let cat): result = result.filter { $0.category == cat }
        default:                 result = []   // My Software modes use their own data sources
        }

        if !searchText.isEmpty {
            let q = searchText.lowercased()
            result = result.filter { item in
                item.displayName.lowercased().contains(q)
                || item.id.lowercased().contains(q)
                || item.publisher?.lowercased().contains(q) == true
                || item.description?.lowercased().contains(q) == true
                || item.keywords.contains { $0.lowercased().contains(q) }
                || item.category?.lowercased().contains(q) == true
            }
        }

        if sortOrder == .alphabetical {
            result.sort {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }

        return result
    }

    private var installedCount:        Int { catalog.items.filter { $0.installedVersion != nil }.count }
    private var notInstalledCount:     Int { catalog.items.filter { $0.installedVersion == nil }.count }
    private var pendingDownloadsCount: Int {
        let stagedIDs = Set(vm.stagedPatches.map { $0.id })
        return vm.managedApps.filter { $0.updateStatus == "updateRequired" && !stagedIDs.contains($0.id) && !$0.isThrottled }.count
    }

    private var sortedCategories: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for item in catalog.items {
            if let cat = item.category { counts[cat, default: 0] += 1 }
        }
        return counts.map { (name: $0.key, count: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Body

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebarContent
                .navigationSplitViewColumnWidth(min: 230, ideal: 270, max: 270)
        } detail: {
            if catalog.items.isEmpty {
                emptyState
            } else {
                mainContent
            }
        }
        .navigationTitle("Available Software")
        .frame(minWidth: 840, minHeight: 680)
        .toolbar {
            if vm.preferences.showHelpButton {
                ToolbarItem(placement: .automatic) {
                    Button { showingHelp.toggle() } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .popover(isPresented: $showingHelp, arrowEdge: .bottom) {
                        SupportInfoView(preferences: vm.preferences)
                    }
                }
            }
        }
        .onAppear {
            catalog.loadItems(preferences: vm.preferences)
        }
        .onChange(of: filterMode) { _, _ in selectedItem = nil }
        .onChange(of: vm.activeLabel) { oldLabel, newLabel in
            if oldLabel != nil && newLabel == nil {
                catalog.loadItems(preferences: vm.preferences)
                if let selected = selectedItem,
                   let refreshed = catalog.items.first(where: { $0.id == selected.id }) {
                    selectedItem = refreshed
                }
            }
        }
    }

    // MARK: - Sidebar

    private var sidebarContent: some View {
        VStack(spacing: 0) {
            VStack(alignment: .center, spacing: 8) {
                CatalogHeaderIcon(preferences: vm.preferences, size: 80)
                    .padding(.top, -20)

                if !vm.preferences.companyName.isEmpty {
                    Text(vm.preferences.companyName)
                        .font(.title3)
                        .fontWeight(.semibold)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 8)
                }

                Text(vm.preferences.appTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
            }

            Divider()
                .padding(.bottom, 8)

            // Using explicit Button rows instead of List(selection:) so that
            // tapping the already-selected item still fires an action and can
            // dismiss the detail view, returning to the grid.
            List {
                Section("Available Software") {
                    sidebarRow(.all,          label: "All Applications", icon: "square.grid.2x2",       badge: catalog.items.count)
                    sidebarRow(.installed,    label: "Installed",        icon: "checkmark.circle.fill",  badge: installedCount)
                    sidebarRow(.notInstalled, label: "Not Installed",    icon: "arrow.down.circle",      badge: notInstalledCount)
                }

                if !sortedCategories.isEmpty {
                    Section(header:
                        Button {
                            withAnimation(.easeInOut(duration: 0.3)) { categoriesExpanded.toggle() }
                        } label: {
                            HStack(spacing: 4) {
                                Text("Categories")
                                Spacer()
                                    .frame(maxWidth: categoriesExpanded ? 144 : 159, alignment: .init(horizontal: .leading, vertical: .center))
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .rotationEffect(.degrees(categoriesExpanded ? 90 : 0))
                            }
                            .padding()
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    ) {
                        if categoriesExpanded {
                            ForEach(sortedCategories, id: \.name) { cat in
                                sidebarRow(.category(cat.name), label: cat.name, icon: "tag", badge: cat.count)
                            }
                        }
                    }
                }

                Divider()
                    .padding(.bottom, -10)
                
                Section("Software Details") {
                    sidebarRow(.managedSoftware,  label: "Managed Software",   icon: "desktopcomputer",         badge: vm.managedApps.count)
                    sidebarRow(.pendingUpdates,   label: "Pending Updates",    icon: "arrow.down.circle.fill",  badge: vm.stagedPatches.count)
                    sidebarRow(.pendingDownloads, label: "Pending Downloads",  icon: "arrow.down.circle",       badge: pendingDownloadsCount)
                    sidebarRow(.updateHistory,    label: "Update History",     icon: "clock.arrow.circlepath",  badge: 0)
                    sidebarRow(.about,            label: "About",              icon: "info.circle.fill",        badge: 0)
                }
            }
            .listStyle(.sidebar)
        }
    }

    private func sidebarRow(_ mode: FilterMode, label: String, icon: String, badge: Int) -> some View {
        Button {
            filterMode = mode
            selectedItem = nil
            selectedStagedPatch = nil
            selectedManagedApp = nil
            selectedHistoryLabel = nil
        } label: {
            Label(label, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .badge(badge)
        .listRowBackground(
            filterMode == mode
                ? RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.18))
                : nil
        )
    }

    // MARK: - Main content

    private var mainContent: some View {
        VStack(spacing: 0) {
            switch filterMode {
            case .pendingUpdates:
                if let patch = selectedStagedPatch {
                    PendingUpdateDetailView(patch: patch, onBack: { selectedStagedPatch = nil })
                        .environmentObject(vm)
                } else {
                    PendingUpdatesGrid(patches: vm.stagedPatches, onSelect: { selectedStagedPatch = $0 })
                        .environmentObject(vm)
                }
            case .pendingDownloads:
                if let app = selectedManagedApp {
                    ManagedAppDetailView(app: app, backLabel: "Pending Downloads", onBack: { selectedManagedApp = nil })
                        .environmentObject(vm)
                } else {
                    let stagedIDs = Set(vm.stagedPatches.map { $0.id })
                    let pending = vm.managedApps.filter { $0.updateStatus == "updateRequired" && !stagedIDs.contains($0.id) && !$0.isThrottled }
                    PendingDownloadsGrid(apps: pending, onSelect: { selectedManagedApp = $0 })
                        .environmentObject(vm)
                }
            case .managedSoftware:
                if let app = selectedManagedApp {
                    ManagedAppDetailView(app: app, onBack: { selectedManagedApp = nil })
                        .environmentObject(vm)
                } else {
                    ManagedSoftwareGrid(apps: vm.managedApps, onSelect: { selectedManagedApp = $0 })
                        .environmentObject(vm)
                }
            case .updateHistory:
                if let label = selectedHistoryLabel {
                    AppHistoryDetailView(
                        label: label,
                        displayName: vm.updateHistory.first(where: { $0.label == label })?.displayName ?? label,
                        iconURL: vm.updateHistory.first(where: { $0.label == label })?.iconURL,
                        entries: vm.updateHistory.filter { $0.label == label },
                        onBack: { selectedHistoryLabel = nil }
                    )
                } else {
                    UpdateHistoryList(history: vm.updateHistory, onSelectLabel: { selectedHistoryLabel = $0 })
                        .environmentObject(vm)
                }
            case .about:
                AboutPanelView(catalog: catalog)
                    .environmentObject(vm)
            default:
                // Catalog modes: all, installed, notInstalled, category
                if let item = selectedItem {
                    ItemDetailView(item: item, onBack: { selectedItem = nil })
                        .environmentObject(vm)
                } else {
                    controlsBar
                    Divider()
                    if filteredItems.isEmpty {
                        noResults
                    } else {
                        gridView
                    }
                }
            }
        }
    }

    private var controlsBar: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.tertiary)
                TextField("Search apps, publishers, keywords…", text: $searchText)
                    .textFieldStyle(.plain)
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 7))

            Picker("Sort", selection: $sortOrder) {
                Text("Default").tag(SortOrder.arrayOrder)
                Text("A–Z").tag(SortOrder.alphabetical)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 120)
            .controlSize(.small)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private var gridView: some View {
        let columns = [GridItem(.adaptive(minimum: 220, maximum: 380), spacing: 10)]
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(filteredItems) { item in
                        CatalogGridItem(item: item, onSelect: { selectedItem = item })
                            .environmentObject(vm)
                    }
                }
                .padding(12)
            }
            .onChange(of: filterMode) { _, _ in
                if let first = filteredItems.first { proxy.scrollTo(first.id, anchor: .top) }
            }
            .onChange(of: sortOrder) { _, _ in
                if let first = filteredItems.first { proxy.scrollTo(first.id, anchor: .top) }
            }
        }
    }

    // MARK: - Empty / no-results states

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No Software Available")
                .font(.headline)
            Text("Your IT team hasn't configured any optional software titles.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 260)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }

    private var noResults: some View {
        VStack(spacing: 8) {
            Image(systemName: searchText.isEmpty ? "checkmark.circle" : "magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            if searchText.isEmpty {
                switch filterMode {
                case .installed:
                    Text("No Apps Installed")
                        .font(.headline)
                    Text("None of the available software titles are currently installed.")
                        .font(.subheadline).foregroundStyle(.secondary)
                case .notInstalled:
                    Text("All Apps Installed")
                        .font(.headline)
                    Text("Every available software title is already installed.")
                        .font(.subheadline).foregroundStyle(.secondary)
                case .category(let cat):
                    Text("No Apps in \"\(cat)\"")
                        .font(.headline)
                    Text("No available software titles are assigned to this category.")
                        .font(.subheadline).foregroundStyle(.secondary)
                case .all:
                    Text("No Software Available")
                        .font(.headline)
                    Text("Your IT team hasn't configured any optional software titles.")
                        .font(.subheadline).foregroundStyle(.secondary)
                default:
                    EmptyView()
                }
            } else {
                Text("No Results for \"\(searchText)\"")
                    .font(.headline)
                Text(filterMode == .all
                     ? "Try a different search term."
                     : "Try a different search term, or select \"All Applications\".")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Catalog Grid item

private struct CatalogGridItem: View {
    let item: CatalogViewModel.CatalogItem
    let onSelect: () -> Void
    @EnvironmentObject var vm: AvailableSoftwareViewModel

    private var isInstalling: Bool { vm.activeLabel == item.id }
    private var isQueued: Bool     { vm.queuedLabel == item.id }
    private var anyActive: Bool    { vm.activeLabel != nil }

    var body: some View {
        Button {
            onSelect()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                appIcon

                VStack(alignment: .leading, spacing: 5) {
                    Text(item.displayName)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let desc = item.description {
                        Text(desc)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 0)

                    HStack {
                        Spacer()
                        installControl
                            .padding(.top, 2)

                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
        }
        .buttonStyle(.accessoryBar)
        .background(Color.secondary.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var appIcon: some View {
        CachedAsyncImage(url: item.iconURL) { image in
            image.resizable().scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 11))
        } placeholder: {
            iconPlaceholder
        }
        .frame(width: 52, height: 52)
    }

    private var iconPlaceholder: some View {
        Image(nsImage: genericAppIcon())
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 11))
    }

    @ViewBuilder
    private var installControl: some View {
        if isInstalling {
            HStack(spacing: 5) {
                ProgressView().scaleEffect(0.65).frame(width: 14, height: 14)
                Text(vm.activeStatus ?? "Installing…").font(.caption).foregroundStyle(.secondary)
            }
        } else if isQueued {
            Text("Queued…")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else {
            Button(item.installedVersion != nil ? "Installed" : "Install") {
                vm.installLabel(item.id)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .foregroundStyle(.blue, .blue)
            .disabled(anyActive || item.installedVersion != nil)
        }
    }
}

// MARK: - Catalog Item detail view (inline, replaces grid)

private struct ItemDetailView: View {
    let item: CatalogViewModel.CatalogItem
    let onBack: () -> Void
    @EnvironmentObject var vm: AvailableSoftwareViewModel

    private var isInstalling: Bool { vm.activeLabel == item.id }
    private var isQueued: Bool     { vm.queuedLabel == item.id }
    private var anyActive: Bool    { vm.activeLabel != nil }

    var body: some View {
        VStack(spacing: 0) {
            // Back navigation bar
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left.circle")
                            .imageScale(.large)

                        Text("Back")
                    }
                    .font(.body)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header row: icon + name/publisher/status + install button
                    HStack(alignment: .top, spacing: 16) {
                        appIcon
                        VStack(alignment: .leading, spacing: 5) {
                            Text(item.displayName)
                                .font(.title)
                                .fontWeight(.bold)
                                .fixedSize(horizontal: false, vertical: true)
                            if let publisher = item.publisher {
                                Label(publisher, systemImage: "building.columns")
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .foregroundStyle(.secondary)
                            }
                            if let category = item.category {
                                Label(category, systemImage: "tag")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            statusText
                        }
                        Spacer(minLength: 12)
                        installControl
                    }
                    .padding(.bottom, 16)

                    if let desc = item.description {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("About")
                                .font(.headline)
                            Divider()
                            Text(desc)
                                .font(.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(.bottom, 16)
                        .textSelection(.enabled)
                    }

                    let links = resolvedLinks
                    if !links.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Links")
                                .font(.headline)
                            Divider()
                            ForEach(links, id: \.title) { entry in
                                Link(destination: entry.url) {
                                    Label(entry.title, systemImage: entry.icon)
                                        .font(.subheadline)
                                }
                            }
                        }
                        .padding(.bottom, 16)
                    }

                    if item.installedVersion != nil {
                        let events = loadHistoryEvents(for: item.id)
                        if !events.isEmpty {
                            historySection(events)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func historySection(_ events: [HistoryEvent]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("History")
                .font(.headline)
            Divider()
            ForEach(events) { event in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: event.icon)
                        .frame(width: 16)
                        .foregroundStyle(event.iconColor)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title)
                            .font(.subheadline)
                        Text(event.date, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
            }
        }
        .padding(.top, 4)
    }

    private struct HistoryEvent: Identifiable {
        let id = UUID()
        let date: Date
        let title: String
        let icon: String
        let iconColor: Color
    }

    private func loadHistoryEvents(for label: String) -> [HistoryEvent] {
        let url = AppConstants.patcherCacheFolderURL
            .appendingPathComponent(label)
            .appendingPathComponent("history.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawEvents = json["events"] as? [[String: Any]]
        else { return [] }

        let iso = ISO8601DateFormatter()
        var events: [HistoryEvent] = []
        var pendingSelfService = false

        for raw in rawEvents {
            guard let type = raw["type"] as? String,
                  let dateStr = raw["date"] as? String,
                  let date = iso.date(from: dateStr)
            else { continue }

            switch type {
            case "selfServiceInstall":
                pendingSelfService = true
            case "discovered":
                let version = raw["installedVersion"] as? String ?? "unknown"
                events.append(HistoryEvent(
                    date: date,
                    title: "Discovered: v\(version)",
                    icon: "magnifyingglass.circle.fill",
                    iconColor: .secondary
                ))
            case "applied":
                let from = raw["fromVersion"] as? String ?? ""
                let to   = raw["toVersion"]   as? String ?? "?"
                if pendingSelfService {
                    events.append(HistoryEvent(
                        date: date,
                        title: "Self-service install: v\(to)",
                        icon: "arrow.down.circle.fill",
                        iconColor: .blue
                    ))
                    pendingSelfService = false
                } else {
                    events.append(HistoryEvent(
                        date: date,
                        title: "Updated: v\(from) → v\(to)",
                        icon: "arrow.up.circle.fill",
                        iconColor: .green
                    ))
                }
            default:
                break
            }
        }

        return events
    }

    private struct AppLink { let title: String; let icon: String; let url: URL }

    private var resolvedLinks: [AppLink] {
        var links: [AppLink] = []
        if let s = item.homepage,      !s.isEmpty, let u = URL(string: s) {
            links.append(.init(title: "Homepage",       icon: "globe",       url: u))
        }
        if let s = item.documentation, !s.isEmpty, let u = URL(string: s) {
            links.append(.init(title: "Documentation",  icon: "doc.text",    url: u))
        }
        if let s = item.privacy,       !s.isEmpty, let u = URL(string: s) {
            links.append(.init(title: "Privacy Policy", icon: "lock.shield", url: u))
        }
        return links
    }

    private var appIcon: some View {
        CachedAsyncImage(url: item.iconURL) { image in
            image.resizable()
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 14))
        } placeholder: {
            iconPlaceholder
        }
        .frame(width: 80, height: 80)
    }

    private var iconPlaceholder: some View {
        Image(nsImage: genericAppIcon())
            .resizable()
            .scaledToFit()
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var statusText: some View {
        if isInstalling {
            Label(vm.activeStatus ?? "Installing…", systemImage: "arrow.down.circle")
                .font(.caption).foregroundStyle(.secondary)
        } else if isQueued {
            Label("Queued — waiting for another operation to complete…", systemImage: "clock")
                .font(.caption).foregroundStyle(.secondary)
        } else if let version = item.installedVersion {
            Label("Version \(version) installed", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        } else {
            Label("Not installed", systemImage: "circle.dashed")
                .font(.caption).foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder
    private var installControl: some View {
        if isInstalling {
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.8)
                Text(vm.activeStatus ?? "Installing…").font(.callout).foregroundStyle(.secondary)
            }
        } else if isQueued {
            Label("Queued…", systemImage: "clock")
                .font(.callout)
                .foregroundStyle(.secondary)
        } else {
            Button(item.installedVersion != nil ? "Installed" : "Install") {
                vm.installLabel(item.id)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(anyActive || item.installedVersion != nil)
            .keyboardShortcut(.init("i", modifiers: [.command]))
        }
    }
}

// MARK: - Catalog header icon

private struct CatalogHeaderIcon: View {
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

            if preferences.useOverlayIcon, let overlay = overlayImage {
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

    private var overlayImage: Image? {
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

// MARK: - Pending Updates

private struct PendingUpdatesGrid: View {
    let patches: [AvailableSoftwareViewModel.StagedPatch]
    let onSelect: (AvailableSoftwareViewModel.StagedPatch) -> Void
    @EnvironmentObject var vm: AvailableSoftwareViewModel

    var body: some View {
        if patches.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36)).foregroundStyle(.green)
                Text("No Pending Updates").font(.headline)
                Text("All managed software is up to date.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            
            HStack (alignment: .center) {
                Text("\(patches.count) Pending Update\(patches.count == 1 ? "" : "s")")
                    .font(.body)
                    .padding(.leading, 20)
             Spacer()
                Button("Apply All Updates") { vm.triggerApply() }
                    .buttonStyle(.borderedProminent).controlSize(.regular)
                    .disabled(patches.count == 0)
                    .padding(9)
                Spacer()
                    .frame(width: 10)
            }
            Divider()
            let columns = [GridItem(.adaptive(minimum: 220, maximum: 380), spacing: 10)]
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(patches) { patch in
                        Button { onSelect(patch) } label: {
                            HStack(alignment: .top, spacing: 12) {
                                CachedAsyncImage(url: patch.iconURL) { img in
                                    img.resizable().scaledToFit()
                                        .clipShape(RoundedRectangle(cornerRadius: 11))
                                } placeholder: {
                                    Image(nsImage: genericAppIcon()).resizable().scaledToFit()
                                        .clipShape(RoundedRectangle(cornerRadius: 11))
                                }
                                .frame(width: 52, height: 52)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(patch.displayName)
                                        .font(.subheadline).fontWeight(.semibold).lineLimit(2)
                                    Label("→ \(patch.newVersion)", systemImage: "arrow.down.circle")
                                        .font(.caption).foregroundStyle(.orange)
                                    if let date = patch.stagedDate {
                                        Text("Staged \(date, format: .relative(presentation: .named))")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
                        }
                        .buttonStyle(.accessoryBar)
                        .background(Color.secondary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(12)
            }
        }
    }
}

private struct PendingUpdateDetailView: View {
    let patch: AvailableSoftwareViewModel.StagedPatch
    let onBack: () -> Void
    @EnvironmentObject var vm: AvailableSoftwareViewModel
    @State private var metadata: LabelMetadata?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left.circle").imageScale(.large)
                        Text("Pending Updates")
                    }.font(.body)
                        .padding(.top, 1)
                }
                .buttonStyle(.borderless).foregroundStyle(.tint)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 16) {
                        CachedAsyncImage(url: patch.iconURL) { img in
                            img.resizable().scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        } placeholder: {
                            Image(nsImage: genericAppIcon()).resizable().scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .frame(width: 80, height: 80)

                        VStack(alignment: .leading, spacing: 5) {
                            Text(patch.displayName).font(.title).fontWeight(.bold)
                                .fixedSize(horizontal: false, vertical: true)
                            if let publisher = metadata?.publisher, !publisher.isEmpty {
                                Label(publisher, systemImage: "building.columns")
                                    .font(.caption).fontWeight(.bold).foregroundStyle(.secondary)
                            }
                            if let date = patch.stagedDate {
                                Label("Staged \(date, format: .relative(presentation: .named))", systemImage: "clock")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Label("Ready to install", systemImage: "arrow.down.circle.fill")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        Spacer(minLength: 12)
                        Button("Apply All Updates") { vm.triggerApply() }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(vm.activeLabel != nil)
                    }
                    .padding(.bottom, 8)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Update").font(.headline)
                        Divider()
                        HStack(spacing: 24) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Available Version").font(.caption).foregroundStyle(.secondary)
                                Text(patch.newVersion).font(.title3).fontWeight(.semibold)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }

                    MetadataInfoSections(metadata: metadata)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { metadata = loadLabelMetadata(for: patch.id) }
    }
}

// MARK: - Managed Software

private struct ManagedSoftwareGrid: View {
    let apps: [AvailableSoftwareViewModel.ManagedApp]
    let onSelect: (AvailableSoftwareViewModel.ManagedApp) -> Void
    @EnvironmentObject var vm: AvailableSoftwareViewModel
    @State private var searchText = ""

    private var filteredApps: [AvailableSoftwareViewModel.ManagedApp] {
        guard !searchText.isEmpty else { return apps }
        let q = searchText.lowercased()
        return apps.filter { app in
            app.displayName.lowercased().contains(q)
            || app.id.lowercased().contains(q)
            || app.publisher?.lowercased().contains(q) == true
            || app.appDescription?.lowercased().contains(q) == true
            || app.keywords.contains { $0.lowercased().contains(q) }
            || app.category?.lowercased().contains(q) == true
        }
    }

    var body: some View {
        if apps.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "tray").font(.system(size: 36)).foregroundStyle(.tertiary)
                Text("No Managed Software").font(.headline)
                Text("No applications have been discovered yet. Run a scan to get started.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                // Search bar
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.tertiary)
                    TextField("Search apps, publishers, keywords…", text: $searchText)
                        .textFieldStyle(.plain)
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Divider()

                if filteredApps.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").font(.system(size: 28)).foregroundStyle(.tertiary)
                        Text("No Results for \"\(searchText)\"").font(.headline)
                        Text("Try a different search term.").font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    let columns = [GridItem(.adaptive(minimum: 220, maximum: 380), spacing: 10)]
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(filteredApps) { app in
                                Button { onSelect(app) } label: {
                                    HStack(alignment: .top, spacing: 12) {
                                        CachedAsyncImage(url: app.iconURL) { img in
                                            img.resizable().scaledToFit()
                                                .clipShape(RoundedRectangle(cornerRadius: 11))
                                        } placeholder: {
                                            Image(nsImage: genericAppIcon()).resizable().scaledToFit()
                                                .clipShape(RoundedRectangle(cornerRadius: 11))
                                        }
                                        .frame(width: 52, height: 52)

                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(app.displayName)
                                                .font(.subheadline).fontWeight(.semibold).lineLimit(2)
                                            managedStatusLabel(app.updateStatus)
                                            Spacer(minLength: 0)
                                            if let appPath = app.primaryAppPath {
                                                HStack {
                                                    Spacer()
                                                    Button("Open") {
                                                        NSWorkspace.shared.open(URL(fileURLWithPath: appPath))
                                                    }
                                                    .buttonStyle(.borderedProminent)
                                                    .foregroundStyle(.blue, .blue)
                                                    .controlSize(.small)
                                                }
                                                .padding(.top, 2)
                                            }
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                    .padding(10)
                                    .frame(maxWidth: .infinity, minHeight: 82, alignment: .topLeading)
                                }
                                .buttonStyle(.accessoryBar)
                                .background(Color.secondary.opacity(0.06))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            }
                        }
                        .padding(12)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func managedStatusLabel(_ status: String) -> some View {
        switch status {
        case "upToDate":
            Label("Up to Date", systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
        case "updateRequired":
            Label("Update Available", systemImage: "arrow.up.circle.fill")
                .font(.caption).foregroundStyle(.orange)
        case "userSpace":
            Label("Out of Scope", systemImage: "house.circle")
                .font(.caption).foregroundStyle(.secondary)
        default:
            Label("Status Unknown", systemImage: "questionmark.circle")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Pending Downloads

private struct PendingDownloadsGrid: View {
    let apps: [AvailableSoftwareViewModel.ManagedApp]
    let onSelect: (AvailableSoftwareViewModel.ManagedApp) -> Void
    @EnvironmentObject var vm: AvailableSoftwareViewModel

    var body: some View {
        if apps.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 36)).foregroundStyle(.green)
                Text("No Pending Downloads").font(.headline)
                Text("Nothing to download at the moment.")
                    .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 280)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HStack(alignment: .center) {
                Text("\(apps.count) Pending Download\(apps.count == 1 ? "" : "s")")
                    .font(.body)
                    .padding(.leading, 20)
                Spacer()
                Button("Download Now") { vm.triggerStage() }
                    .buttonStyle(.borderedProminent).controlSize(.regular)
                    .padding(9)
                Spacer()
                    .frame(width: 10)
            }
            Divider()
            let columns = [GridItem(.adaptive(minimum: 220, maximum: 380), spacing: 10)]
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(apps) { app in
                        Button { onSelect(app) } label: {
                            HStack(alignment: .top, spacing: 12) {
                                CachedAsyncImage(url: app.iconURL) { img in
                                    img.resizable().scaledToFit()
                                        .clipShape(RoundedRectangle(cornerRadius: 11))
                                } placeholder: {
                                    Image(nsImage: genericAppIcon()).resizable().scaledToFit()
                                        .clipShape(RoundedRectangle(cornerRadius: 11))
                                }
                                .frame(width: 52, height: 52)

                                VStack(alignment: .leading, spacing: 4) {
                                    Text(app.displayName)
                                        .font(.subheadline).fontWeight(.semibold).lineLimit(2)
                                    Label("Update Available", systemImage: "arrow.down.circle")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(10)
                            .frame(maxWidth: .infinity, minHeight: 76, alignment: .topLeading)
                        }
                        .buttonStyle(.accessoryBar)
                        .background(Color.secondary.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                }
                .padding(12)
            }
        }
    }
}

private struct ManagedAppDetailView: View {
    let app: AvailableSoftwareViewModel.ManagedApp
    var backLabel: String = "Managed Software"
    let onBack: () -> Void
    @EnvironmentObject var vm: AvailableSoftwareViewModel
    @State private var metadata: LabelMetadata?

    private var appHistory: [AvailableSoftwareViewModel.HistoryEntry] {
        vm.updateHistory.filter { $0.label == app.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left.circle").imageScale(.large)
                        Text(backLabel)
                    }.font(.body)
                }
                .buttonStyle(.borderless).foregroundStyle(.tint)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 16) {
                        CachedAsyncImage(url: app.iconURL) { img in
                            img.resizable().scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        } placeholder: {
                            Image(nsImage: genericAppIcon()).resizable().scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .frame(width: 80, height: 80)

                        VStack(alignment: .leading, spacing: 5) {
                            Text(app.displayName).font(.title).fontWeight(.bold)
                                .fixedSize(horizontal: false, vertical: true)
                            if let publisher = metadata?.publisher, !publisher.isEmpty {
                                Label(publisher, systemImage: "building.columns")
                                    .font(.caption).fontWeight(.bold).foregroundStyle(.secondary)
                            }
                            Label(app.id, systemImage: "tag")
                                .font(.caption).foregroundStyle(.secondary)
                            switch app.updateStatus {
                            case "upToDate":
                                Label("Up to Date", systemImage: "checkmark.circle.fill")
                                    .font(.caption).foregroundStyle(.green)
                            case "updateRequired":
                                Label("Update Available", systemImage: "arrow.up.circle.fill")
                                    .font(.caption).foregroundStyle(.orange)
                            case "userSpace":
                                Label("Out of Scope — installed in user space", systemImage: "house.circle")
                                    .font(.caption).foregroundStyle(.secondary)
                            default:
                                Label("Status Unknown", systemImage: "questionmark.circle")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer(minLength: 12)
                        if let appPath = app.primaryAppPath {
                            Button("Open") {
                                NSWorkspace.shared.open(URL(fileURLWithPath: appPath))
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        }
                    }
                    .padding(.bottom, 8)

                    MetadataInfoSections(metadata: metadata)

                    if !app.installPaths.isEmpty {
                        locationSection
                    }

                    if !appHistory.isEmpty {
                        historySection
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { metadata = loadLabelMetadata(for: app.id) }
    }

    private var locationSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Location").font(.headline)
            Divider()
            ForEach(app.installPaths, id: \.self) { path in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: path.hasSuffix(".app") ? "app.badge" : "folder")
                        .frame(width: 16).foregroundStyle(.secondary)
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                        .frame(width: 2)
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: path)]
                        )
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Reveal in Finder")
                    
                }
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("History").font(.headline)
            Divider()
            ForEach(appHistory) { entry in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: historyIcon(entry))
                        .frame(width: 16).foregroundStyle(historyColor(entry))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(historyTitle(entry)).font(.subheadline)
                        Text(entry.date, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .textSelection(.enabled)
            }
        }
    }
}

// MARK: - Update History

private struct UpdateHistoryList: View {
    let history: [AvailableSoftwareViewModel.HistoryEntry]
    let onSelectLabel: (String) -> Void
    @EnvironmentObject var vm: AvailableSoftwareViewModel
    @State private var filterType = "all"

    private var filteredHistory: [AvailableSoftwareViewModel.HistoryEntry] {
        switch filterType {
        case "applied":     return history.filter { $0.eventType == "applied" }
        case "selfService": return history.filter { $0.eventType == "selfService" }
        case "discovered":  return history.filter { $0.eventType == "discovered" }
        default:            return history
        }
    }

    private var grouped: [(key: String, entries: [AvailableSoftwareViewModel.HistoryEntry])] {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMMM yyyy"
        var groups: [(key: String, entries: [AvailableSoftwareViewModel.HistoryEntry])] = []
        var seen: [String: Int] = [:]
        for entry in filteredHistory {
            let key = fmt.string(from: entry.date)
            if let idx = seen[key] {
                groups[idx].entries.append(entry)
            } else {
                seen[key] = groups.count
                groups.append((key: key, entries: [entry]))
            }
        }
        return groups
    }

    var body: some View {
        if history.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "clock").font(.system(size: 36)).foregroundStyle(.tertiary)
                Text("No Update History").font(.headline)
                Text("Patcher hasn't applied any updates yet.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                Picker("Filter", selection: $filterType) {
                    Text("All").tag("all")
                    Text("Updates").tag("applied")
                    Text("Self-Service").tag("selfService")
                    Text("Discovered").tag("discovered")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 16)
                .padding(.vertical, 8)

                Divider()

                if filteredHistory.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 28)).foregroundStyle(.tertiary)
                        Text("No Matching Events").font(.headline)
                        Text("No history entries match the selected filter.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(grouped, id: \.key) { group in
                            Section(group.key) {
                                ForEach(group.entries) { entry in
                                    Button { onSelectLabel(entry.label) } label: {
                                        HStack(spacing: 12) {
                                            CachedAsyncImage(url: entry.iconURL) { img in
                                                img.resizable().scaledToFit()
                                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                            } placeholder: {
                                                Image(nsImage: genericAppIcon()).resizable().scaledToFit()
                                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                            }
                                            .frame(width: 32, height: 32)

                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(entry.displayName).font(.subheadline).fontWeight(.medium)
                                                Text(historyTitle(entry)).font(.caption).foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                            Text(entry.date, format: .relative(presentation: .named))
                                                .font(.caption2).foregroundStyle(.tertiary)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

private struct AppHistoryDetailView: View {
    let label: String
    let displayName: String
    let iconURL: URL?
    let entries: [AvailableSoftwareViewModel.HistoryEntry]
    let onBack: () -> Void
    @State private var metadata: LabelMetadata?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onBack) {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left.circle").imageScale(.large)
                        Text("Update History")
                    }.font(.body)
                }
                .buttonStyle(.borderless).foregroundStyle(.tint)
                Spacer()
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    HStack(alignment: .top, spacing: 16) {
                        CachedAsyncImage(url: iconURL) { img in
                            img.resizable().scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        } placeholder: {
                            Image(nsImage: genericAppIcon()).resizable().scaledToFit()
                                .clipShape(RoundedRectangle(cornerRadius: 14))
                        }
                        .frame(width: 80, height: 80)
                        VStack(alignment: .leading, spacing: 5) {
                            Text(displayName).font(.title).fontWeight(.bold)
                                .fixedSize(horizontal: false, vertical: true)
                            if let publisher = metadata?.publisher, !publisher.isEmpty {
                                Label(publisher, systemImage: "building.columns")
                                    .font(.caption).fontWeight(.bold).foregroundStyle(.secondary)
                            }
                            Label(label, systemImage: "tag")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                    }
                    .padding(.bottom, 8)

                    MetadataInfoSections(metadata: metadata)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("History").font(.headline)
                        Divider()
                        ForEach(entries) { entry in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: historyIcon(entry))
                                    .frame(width: 16).foregroundStyle(historyColor(entry))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(historyTitle(entry)).font(.subheadline)
                                    Text(entry.date, format: .dateTime.year().month(.abbreviated).day().hour().minute())
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .textSelection(.enabled)
                        }
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task { metadata = loadLabelMetadata(for: label) }
    }
}

// MARK: - Label metadata helpers (shared by My Software detail views)

private struct LabelMetadata {
    var publisher:     String?
    var description:   String?
    var homepage:      String?
    var documentation: String?
    var privacy:       String?
}

/// Loads plist metadata for a label, checking admin-managed then synced repo.
/// Respects the user's preferred language with an English fallback.
/// Returns nil when no metadata file exists in either location.
private func loadLabelMetadata(for label: String) -> LabelMetadata? {
    let langCode = (Locale.preferredLanguages.first ?? "en")
        .components(separatedBy: "-").first ?? "en"
    let managed = AppConstants.managedMetadataFolderURL
    let synced  = AppConstants.installomatorMetadataFolderURL.appendingPathComponent("Metadata")

    var candidates: [URL] = []
    if langCode != "en" {
        candidates.append(managed.appendingPathComponent("\(langCode)/\(label).plist"))
        candidates.append(managed.appendingPathComponent("\(label).plist"))
        candidates.append(synced.appendingPathComponent("\(langCode)/\(label).plist"))
    } else {
        candidates.append(managed.appendingPathComponent("\(label).plist"))
    }
    candidates.append(synced.appendingPathComponent("\(label).plist"))

    for url in candidates {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { continue }
        return LabelMetadata(
            publisher:     dict["Publisher"]     as? String,
            description:   dict["Description"]   as? String,
            homepage:      dict["Homepage"]       as? String,
            documentation: dict["Documentation"]  as? String,
            privacy:       dict["Privacy"]        as? String
        )
    }
    return nil
}

/// Renders the About (description) and Links (homepage/docs/privacy) sections
/// from synced label metadata, matching the style used in the catalog detail view.
private struct MetadataInfoSections: View {
    let metadata: LabelMetadata?

    private struct AppLink { let title: String; let icon: String; let url: URL }

    private var links: [AppLink] {
        guard let m = metadata else { return [] }
        var result: [AppLink] = []
        if let s = m.homepage,      !s.isEmpty, let u = URL(string: s) {
            result.append(.init(title: "Homepage",       icon: "globe",       url: u))
        }
        if let s = m.documentation, !s.isEmpty, let u = URL(string: s) {
            result.append(.init(title: "Documentation",  icon: "doc.text",    url: u))
        }
        if let s = m.privacy,       !s.isEmpty, let u = URL(string: s) {
            result.append(.init(title: "Privacy Policy", icon: "lock.shield", url: u))
        }
        return result
    }

    var body: some View {
        if let desc = metadata?.description, !desc.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("About").font(.headline)
                Divider()
                Text(desc).font(.body).fixedSize(horizontal: false, vertical: true)
            }
            .textSelection(.enabled)
        }
        if !links.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Links").font(.headline)
                Divider()
                ForEach(links, id: \.title) { entry in
                    Link(destination: entry.url) {
                        Label(entry.title, systemImage: entry.icon).font(.subheadline)
                    }
                }
            }
        }
    }
}

// MARK: - History helpers (shared by Managed and History detail views)

private func historyIcon(_ entry: AvailableSoftwareViewModel.HistoryEntry) -> String {
    switch entry.eventType {
    case "applied":      return "arrow.up.circle.fill"
    case "selfService":  return "arrow.down.circle.fill"
    case "discovered":   return "magnifyingglass.circle.fill"
    default:             return "circle.fill"
    }
}

private func historyColor(_ entry: AvailableSoftwareViewModel.HistoryEntry) -> Color {
    switch entry.eventType {
    case "applied":      return .green
    case "selfService":  return .blue
    case "discovered":   return .secondary
    default:             return .secondary
    }
}

private func historyTitle(_ entry: AvailableSoftwareViewModel.HistoryEntry) -> String {
    switch entry.eventType {
    case "applied":
        let from = entry.fromVersion ?? "?"
        let to   = entry.toVersion   ?? "?"
        return "Updated: v\(from) → v\(to)"
    case "selfService":
        return "Self-service install: v\(entry.toVersion ?? "?")"
    case "discovered":
        return "Discovered: v\(entry.toVersion ?? "unknown")"
    default:
        return entry.eventType
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

// MARK: - About Panel

private struct AboutPanelView: View {
    let catalog: CatalogViewModel
    @EnvironmentObject var vm: AvailableSoftwareViewModel
    @State private var showDiagnostics = false

    private var installedCount: Int {
        catalog.items.filter { $0.installedVersion != nil }.count
    }

    private var appliedCount: Int {
        vm.updateHistory.filter { $0.eventType == "applied" || $0.eventType == "selfService" }.count
    }

    private var uniqueAppsUpdated: Int {
        Set(vm.updateHistory
            .filter { $0.eventType == "applied" || $0.eventType == "selfService" }
            .map { $0.label }
        ).count
    }

    private var installomatorVersion: String {
        (try? String(contentsOf: AppConstants.installomatorVersionFileURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "Not installed"
    }

    private var managedLabelsVersion: String {
        (try? String(contentsOf: AppConstants.managedLabelsVersionFileURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nilIfEmpty ?? "Not configured"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // App identity
                HStack(spacing: 16) {
                    // Control+Option+Shift+click reveals the preferences diagnostic sheet.
                    Button {
                        let flags = NSEvent.modifierFlags
                        if flags.contains(.control) && flags.contains(.option) && flags.contains(.shift) {
                            showDiagnostics = true
                        }
                    } label: {
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 100, height: 100)
                    }
                    .buttonStyle(.plain)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppConstants.patcherFullName)
                            .font(.title2).fontWeight(.semibold)
                        Text("Version \(AppConstants.patcherVersion)")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, -20)
                .padding(.bottom, 0)

                // Label Library
                aboutSection("Label Library") {
                    infoRow("Installomator Labels",  value: installomatorVersion)
                    infoRow("Managed Labels",        value: managedLabelsVersion)
                    infoRow("Available in Catalog",  value: "\(catalog.items.count) apps")
                    infoRow("Currently Installed",   value: "\(installedCount) apps")
                }

                // Update Statistics
                aboutSection("Update Statistics") {
                    infoRow("Apps Under Management",      value: "\(vm.managedApps.count)")
                    infoRow("Updates Applied (All Time)", value: "\(appliedCount)")
                    infoRow("Unique Apps Updated",        value: "\(uniqueAppsUpdated)")
                    infoRow("Pending Updates",            value: "\(vm.stagedPatches.count)")
                }

                // Last Activity
                if let snap = vm.schedulerSnapshot {
                    aboutSection("Last Activity") {
                        activityRow("Scan",          date: snap.lastScanDate)
                        activityRow("Check",         date: snap.lastCheckDate)
                        activityRow("Stage",         date: snap.lastStageDate)
                        activityRow("Apply",         date: snap.lastApplyDate)
//                        activityRow("Metadata Sync", date: snap.lastMetaSyncDate)
                    }
                }

                // System
                aboutSection("System") {
                    infoRow("macOS", value: ProcessInfo.processInfo.operatingSystemVersionString)
                    if let host = Host.current().localizedName, !host.isEmpty {
                        infoRow("Computer", value: host)
                    }
                }

                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(isPresented: $showDiagnostics) {
            PreferencesDebugSheet(preferences: vm.preferences)
        }
    }

    private func aboutSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            Divider()
            content()
        }
    }

    private func infoRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
    }

    private func activityRow(_ label: String, date: Date?) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            if let d = date {
                Text(d, format: .relative(presentation: .named, unitsStyle: .wide))
                    .multilineTextAlignment(.trailing)
            } else {
                Text("Never").foregroundStyle(.tertiary)
            }
        }
        .font(.subheadline)
    }
}

// MARK: - Preferences diagnostic sheet

private struct PreferencesDebugSheet: View {
    let preferences: Preferences
    @State private var expandedKeys: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Preferences Diagnostic")
                        .font(.headline)
                    Text("Source: \(preferences.source)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            let entries = preferences.rawEntries
            if entries.isEmpty {
                Text("No preferences configured — all defaults in use.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(entries, id: \.key) { entry in
                            prefRow(key: entry.key, value: entry.value)
                            Divider()
                        }
                    }
                    .padding(.horizontal)
                }
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 600, idealHeight: 630)
    }

    @ViewBuilder
    private func prefRow(key: String, value: Any) -> some View {
        let fv = formatted(value)
        let isExpanded = expandedKeys.contains(key)

        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center) {
                Text(key)
                    .font(.system(.subheadline, design: .monospaced))
                    .fontWeight(.medium)
                Spacer()
                if fv.isLong {
                    Button {
                        if isExpanded { expandedKeys.remove(key) }
                        else { expandedKeys.insert(key) }
                    } label: {
                        Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(isExpanded || !fv.isLong ? fv.full : fv.preview)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 8)
    }

    private struct FormattedValue {
        let preview: String
        let full: String
        var isLong: Bool { preview != full }
    }

    private func formatted(_ value: Any) -> FormattedValue {
        let full: String
        switch value {
        case let n as NSNumber where CFGetTypeID(n as CFTypeRef) == CFBooleanGetTypeID():
            full = n.boolValue ? "true" : "false"
        case let arr as [Any]:
            full = arr.map { "\($0)" }.joined(separator: "\n")
        case let dict as [String: Any]:
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]),
               let str = String(data: data, encoding: .utf8) {
                full = str
            } else {
                full = "\(dict)"
            }
        default:
            full = "\(value)"
        }

        let lines = full.components(separatedBy: "\n")
        if lines.count > 3 {
            let preview = lines.prefix(3).joined(separator: "\n") + "\n  … +\(lines.count - 3) more"
            return FormattedValue(preview: preview, full: full)
        }
        if full.count > 120 {
            return FormattedValue(preview: String(full.prefix(120)) + "…", full: full)
        }
        return FormattedValue(preview: full, full: full)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
