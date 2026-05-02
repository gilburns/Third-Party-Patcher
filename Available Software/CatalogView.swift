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
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    enum SortOrder  { case arrayOrder, alphabetical }
    enum FilterMode: Hashable { case all, installed, notInstalled, category(String) }

    private var filteredItems: [CatalogViewModel.CatalogItem] {
        var result = catalog.items

        switch filterMode {
        case .all:               break
        case .installed:         result = result.filter { $0.installedVersion != nil }
        case .notInstalled:      result = result.filter { $0.installedVersion == nil }
        case .category(let cat): result = result.filter { $0.category == cat }
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

    private var installedCount:    Int { catalog.items.filter { $0.installedVersion != nil }.count }
    private var notInstalledCount: Int { catalog.items.filter { $0.installedVersion == nil }.count }

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
                .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
        } detail: {
            if catalog.items.isEmpty {
                emptyState
            } else {
                mainContent
            }
        }
        .navigationTitle("Available Software")
        .frame(minWidth: 580, minHeight: 500)
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

            List(selection: $filterMode) {
                Section {
                    Label("All Applications", systemImage: "square.grid.2x2")
                        .badge(catalog.items.count)
                        .tag(FilterMode.all)

                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .badge(installedCount)
                        .tag(FilterMode.installed)

                    Label("Not Installed", systemImage: "arrow.down.circle")
                        .badge(notInstalledCount)
                        .tag(FilterMode.notInstalled)
                }

                if !sortedCategories.isEmpty {
                    Section("Categories") {
                        ForEach(sortedCategories, id: \.name) { cat in
                            Label(cat.name, systemImage: "tag")
                                .badge(cat.count)
                                .tag(FilterMode.category(cat.name))
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            

        }
    }

    // MARK: - Main content

    private var mainContent: some View {
        VStack(spacing: 0) {
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

// MARK: - Grid item

private struct CatalogGridItem: View {
    let item: CatalogViewModel.CatalogItem
    let onSelect: () -> Void
    @EnvironmentObject var vm: AvailableSoftwareViewModel

    private var isInstalling: Bool { vm.activeLabel == item.id }
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

// MARK: - Item detail view (inline, replaces grid)

private struct ItemDetailView: View {
    let item: CatalogViewModel.CatalogItem
    let onBack: () -> Void
    @EnvironmentObject var vm: AvailableSoftwareViewModel

    private var isInstalling: Bool { vm.activeLabel == item.id }
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
