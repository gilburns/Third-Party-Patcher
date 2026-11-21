//
//  DialogViews.swift
//  PatcherNotifier
//
//  SwiftUI views for the windows described by DialogSession.
//

import Combine
import SwiftUI

/// What the user did to a window.
enum DialogAction {
    /// The default button: Done, OK, or Skip Update.
    case primary
    /// Quit <App>.
    case secondary
    /// The quit key or the title-bar close button.
    case dismissed
}

/// The live state of one window. DialogWindow replaces `session` whenever its file changes.
final class DialogModel: ObservableObject {
    @Published var session: DialogSession
    /// Set by DialogWindow.
    var onAction: (DialogAction) -> Void = { _ in }
    /// The menu choice, sent back with the primary button.
    var selection: String?

    init(session: DialogSession) {
        self.session = session
        self.selection = session.menu?.selected
    }
}

enum DialogLayout {
    static let listWidth: CGFloat = 770
    static let compactSize = CGSize(width: 560, height: 124)
    static let promptSize  = CGSize(width: 480, height: 320)
    static let noticeSize  = CGSize(width: 600, height: 250)
    static let deferralWidth: CGFloat = 680

    static func deferralHeight(itemCount: Int) -> CGFloat {
        min(640, max(440, 300 + CGFloat(itemCount) * 60))
    }

    static func listHeight(itemCount: Int) -> CGFloat {
        min(520, max(450, 220 + CGFloat(itemCount) * 60))
    }
}

struct DialogRootView: View {
    @ObservedObject var model: DialogModel

    var body: some View {
        switch model.session.kind {
        case .applyList:
            ApplyListView(session: model.session, onDone: { model.onAction(.primary) })
        case .applyCompact, .progress:
            CompactProgressView(session: model.session)
        case .blockingNotice, .blockingPrompt:
            BlockingAppView(session: model.session, onAction: model.onAction)
        case .deferral:
            DeferralView(model: model)
        }
    }
}

// MARK: - Markdown

/// Inline Markdown (bold, italic, code, links), keeping line breaks.
struct MarkdownText: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        if let attributed = try? AttributedString(markdown: text, options: options) {
            Text(attributed)
        } else {
            Text(text)
        }
    }
}

// MARK: - Icons

/// An icon spec, with an optional overlay badge in the bottom-right corner.
struct DialogIconView: View {
    let spec: String?
    var overlay: String? = nil
    let size: CGFloat

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            SpecImage(spec: spec, fallbackSymbol: "app.dashed")
                .frame(width: size, height: size)
            if let overlay, !overlay.isEmpty {
                SpecImage(spec: overlay, fallbackSymbol: nil)
                    .frame(width: size * 0.45, height: size * 0.45)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    .offset(x: size * 0.08, y: size * 0.08)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

private struct SpecImage: View {
    let spec: String?
    let fallbackSymbol: String?
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
            } else if let fallbackSymbol {
                Image(systemName: fallbackSymbol).resizable().scaledToFit().foregroundStyle(.tertiary)
            } else {
                Color.clear
            }
        }
        .task(id: spec) {
            guard let spec else { image = nil; return }
            image = await IconLoader.shared.image(for: spec)
        }
    }
}

// MARK: - Progress

struct SessionProgressBar: View {
    let progress: DialogSession.Progress

    var body: some View {
        if progress.indeterminate || progress.total <= 0 {
            ProgressView().progressViewStyle(.linear)
        } else {
            ProgressView(value: Double(min(progress.current, progress.total)), total: Double(progress.total))
                .progressViewStyle(.linear)
                .animation(.easeOut(duration: 0.25), value: progress.current)
        }
    }
}

// MARK: - Large apply window

struct ApplyListView: View {
    let session: DialogSession
    let onDone: () -> Void

    private var brandText: Color { Color(nsColor: NSColor(hex: session.branding.textColorHex) ?? .white) }
    private var brandBackground: Color { Color(nsColor: NSColor(hex: session.branding.backgroundColorHex) ?? .systemBlue) }

    var body: some View {
        HStack(spacing: 0) {
            sidePanel
            VStack(alignment: .leading, spacing: 0) {
                Text(session.title)
                    .font(.system(size: 18, weight: .semibold))
                    .padding(.horizontal, 20)
                    .padding(.top, 22)
                    .padding(.bottom, 12)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(session.items) { item in
                            ItemRow(item: item)
                            if item.id != session.items.last?.id { Divider().padding(.leading, 64) }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
                .padding(.horizontal, 20)

                VStack(alignment: .leading, spacing: 6) {
                    SessionProgressBar(progress: session.progress)
                    Text(session.progress.text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)

                HStack {
                    if let help = session.help { HelpButton(help: help) }
                    Spacer()
                    if let button = session.button {
                        Button(button.title, action: onDone)
                            .keyboardShortcut(.defaultAction)
                            .controlSize(.large)
                            .disabled(!button.enabled)
                    }
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 20) {
            DialogIconView(spec: session.icon, overlay: session.overlayIcon, size: 128)
                .padding(.top, 12)
            if let text = session.sidePanel {
                MarkdownText(text)
                    .font(.system(size: 14))
                    .foregroundStyle(brandText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .frame(width: 240, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(brandBackground)
    }
}

private struct ItemRow: View {
    let item: DialogSession.Item

    var body: some View {
        HStack(spacing: 12) {
            DialogIconView(spec: item.icon, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Text(item.statusText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            StatusSymbol(status: item.status)
                .frame(width: 20, height: 20)
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }
}

private struct StatusSymbol: View {
    let status: DialogSession.Item.Status

    var body: some View {
        switch status {
        case .pending:
            Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
        case .working:
            ProgressView().controlSize(.small)
        case .success:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed:
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
        case .skipped:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .ready:
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
        case .blocked:
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
        }
    }
}

// MARK: - Help

private struct HelpButton: View {
    let help: DialogSession.Help
    @State private var isShown = false

    var body: some View {
        Button { isShown.toggle() } label: {
            Image(systemName: "questionmark")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.bordered)
        .clipShape(Circle())
        .help("Support and computer information")
        .accessibilityLabel("Help")
        .popover(isPresented: $isShown, arrowEdge: .top) {
            HelpView(help: help)
        }
    }
}

private struct HelpView: View {
    let help: DialogSession.Help

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("For assistance with this update, contact **\(help.supportTeamName)**.")
                .fixedSize(horizontal: false, vertical: true)
            if !help.contact.isEmpty { section(nil, help.contact) }
            section("Computer", help.computer)
            section("Software", help.software)
        }
        .padding(18)
        .frame(width: 340, alignment: .leading)
    }

    @ViewBuilder
    private func section(_ title: String?, _ rows: [DialogSession.Help.Row]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
            }
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    GridRow {
                        Text(row.label).foregroundStyle(.secondary)
                        if let link = row.link, let url = URL(string: link) {
                            Link(row.value, destination: url)
                        } else {
                            Text(row.value).textSelection(.enabled)
                        }
                    }
                }
            }
            .font(.callout)
        }
    }
}

// MARK: - Compact apply and scan / check / stage

struct CompactProgressView: View {
    let session: DialogSession

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            DialogIconView(spec: session.icon, overlay: session.overlayIcon, size: 80)
            // The title is in the window's title bar, as in swiftDialog's mini window.
            VStack(alignment: .leading, spacing: 6) {
                MarkdownText(session.message)
                    .font(.system(size: 13))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                SessionProgressBar(progress: session.progress)
                Text(session.progress.text.isEmpty ? " " : session.progress.text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(width: DialogLayout.compactSize.width, height: DialogLayout.compactSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

// MARK: - Blocking-app notice and prompt

struct BlockingAppView: View {
    let session: DialogSession
    let onAction: (DialogAction) -> Void

    private var brandText: Color { Color(nsColor: NSColor(hex: session.branding.textColorHex) ?? .white) }
    private var brandBackground: Color { Color(nsColor: NSColor(hex: session.branding.backgroundColorHex) ?? .systemBlue) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(session.title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(brandText)
                .lineLimit(1)
                .padding(.horizontal, 20)
                .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                .background(brandBackground)

            HStack(alignment: .top, spacing: 16) {
                DialogIconView(spec: session.icon, overlay: session.overlayIcon, size: 80)
                MarkdownText(session.message)
                    .font(.system(size: session.kind == .blockingNotice ? 15 : 13))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            Spacer(minLength: 12)

            if let countdown = session.countdown {
                CountdownView(countdown: countdown)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)
            }

            HStack(spacing: 10) {
                Spacer()
                if let secondary = session.secondaryButton {
                    Button(secondary.title) { onAction(.secondary) }
                        .controlSize(.large)
                        .disabled(!secondary.enabled)
                }
                if let button = session.button {
                    Button(button.title) { onAction(.primary) }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                        .disabled(!button.enabled)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        // Fill the window, whatever its exact height, so spare room goes above the countdown
        // rather than below the buttons. The window is sized from DialogLayout.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        // The title bar is hidden; don't leave room for it above the banner.
        .ignoresSafeArea()
    }
}

/// A bar that drains as patcher's countdown runs, with the time left.
private struct CountdownView: View {
    let countdown: DialogSession.Countdown

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let total     = Double(max(countdown.seconds, 1))
            let remaining = min(max(countdown.ends.timeIntervalSince(context.date), 0), total)
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: remaining, total: total)
                    .progressViewStyle(.linear)
                Text("Time remaining: \(Self.format(remaining))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private static func format(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.up))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Deferral prompt

struct DeferralView: View {
    @ObservedObject var model: DialogModel
    @State private var selected: String = ""

    private var session: DialogSession { model.session }
    private var brandText: Color { Color(nsColor: NSColor(hex: session.branding.textColorHex) ?? .white) }
    private var brandBackground: Color { Color(nsColor: NSColor(hex: session.branding.backgroundColorHex) ?? .systemBlue) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(session.branding.appTitle)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(brandText)
                .lineLimit(1)
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
                .background(brandBackground)

            HStack(alignment: .top, spacing: 20) {
                VStack(alignment: .leading, spacing: 16) {
                    DialogIconView(spec: session.icon, overlay: session.overlayIcon, size: 96)
                    if let status = session.sidePanel {
                        MarkdownText(status)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 140, alignment: .leading)

                VStack(alignment: .leading, spacing: 12) {
                    MarkdownText(session.message)
                        .font(.system(size: 14))
                        .fixedSize(horizontal: false, vertical: true)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(session.items) { item in
                                ItemRow(item: item)
                                if item.id != session.items.last?.id { Divider().padding(.leading, 52) }
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 20)

            if let countdown = session.countdown {
                CountdownView(countdown: countdown)
                    .padding(.horizontal, 24)
                    .padding(.top, 12)
            }

            HStack(spacing: 10) {
                if let menu = session.menu {
                    Picker(menu.title, selection: $selected) {
                        ForEach(menu.options, id: \.value) { option in
                            Text(option.label).tag(option.value)
                        }
                    }
                    .fixedSize()
                    .onChange(of: selected) { _, value in model.selection = value }
                }
                Spacer()
                if let secondary = session.secondaryButton {
                    Button(secondary.title) { model.onAction(.secondary) }
                        .controlSize(.large)
                        .disabled(!secondary.enabled)
                }
                if let button = session.button {
                    Button(button.title) { model.onAction(.primary) }
                        .keyboardShortcut(.defaultAction)
                        .controlSize(.large)
                        .disabled(!button.enabled)
                }
            }
            .padding(.horizontal, 24)
            .padding(.top, 14)
            .padding(.bottom, 16)
        }
        // Fill the window, whatever its exact height, so spare room goes to the item list
        // rather than below the buttons. The window is sized from DialogLayout.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        // The title bar is hidden; don't leave room for it above the banner.
        .ignoresSafeArea()
        .onAppear { selected = model.selection ?? session.menu?.selected ?? "" }
    }
}
