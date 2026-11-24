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
    /// The default button: Done, OK, Skip Update, or Install while choosing.
    case primary
    /// Quit <App>, or Defer All while choosing.
    case secondary
    /// The quit key or the title-bar close button.
    case dismissed
}

/// The live state of one window. DialogWindow replaces `session` whenever its file changes.
final class DialogModel: ObservableObject {
    @Published var session: DialogSession
    /// Set by DialogWindow.
    var onAction: (DialogAction) -> Void = { _ in }
    /// The menu choice, sent back with the primary button (Defer All while choosing).
    var selection: String?
    /// While choosing: rows the user unchecked.
    @Published var deselected: Set<String>
    /// The checkbox state, reported on each change and sent with the secondary button.
    var checked: Bool
    /// Set by DialogWindow.
    var onToggle: (Bool) -> Void = { _ in }

    init(session: DialogSession) {
        self.session = session
        self.selection = session.menu?.selected
        self.checked = session.checkbox?.checked ?? false
        self.deselected = Set(session.items.filter { $0.selected == false }.map(\.id))
    }

    /// While choosing: what Install sends back.
    var choice: DialogChoice {
        DialogChoice(deferred: session.selectableIDs.intersection(deselected).sorted(),
                     minutes: session.menu == nil ? nil : selection)
    }
}

enum DialogLayout {
    static let listWidth: CGFloat = 770
    /// The compact window's branded header, in place of a title bar.
    static let compactHeaderHeight: CGFloat = 34
    /// The body: the 80pt icon and 14pt padding, with a two-line message, the progress bar
    /// and its caption beside it.
    static let compactSize = CGSize(width: 560, height: 110 + compactHeaderHeight)
    static let promptSize  = CGSize(width: 480, height: 320)
    static let noticeSize  = CGSize(width: 600, height: 250)

    /// Room for the choosing phase's message too, so the window keeps one size from
    /// choosing through installing.
    static func listHeight(itemCount: Int) -> CGFloat {
        min(580, max(480, 260 + CGFloat(itemCount) * 60))
    }
}

struct DialogRootView: View {
    @ObservedObject var model: DialogModel

    var body: some View {
        switch model.session.kind {
        case .applyList:
            ApplyListView(model: model)
        case .applyCompact, .progress:
            CompactProgressView(session: model.session)
        case .blockingNotice, .blockingPrompt:
            BlockingAppView(model: model)
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
            ProgressView(value: min(Double(progress.current) + (progress.fraction ?? 0), Double(progress.total)),
                         total: Double(progress.total))
                .progressViewStyle(.linear)
                .animation(.easeOut(duration: 0.25), value: Double(progress.current) + (progress.fraction ?? 0))
        }
    }
}

// MARK: - Large apply window

struct ApplyListView: View {
    @ObservedObject var model: DialogModel
    @State private var menuChoice = ""

    private var session: DialogSession { model.session }
    private var choosing: Bool { session.phase == .choosing }
    private var brandText: Color { session.branding.textColor }
    private var brandBackground: Color { session.branding.backgroundColor }

    /// While choosing, the rows still checked (rows without a checkbox always install).
    private var installCount: Int { session.items.count - session.selectableIDs.intersection(model.deselected).count }

    private var primaryTitle: String {
        guard let button = session.button else { return "" }
        guard choosing, !session.selectableIDs.isEmpty else { return button.title }
        return installCount == session.items.count
            ? DialogText.installAllNow.text
            : String(localized: "Install \(installCount) Now",
                     comment: "Deferral prompt button: installs the apps still checked")
    }

    var body: some View {
        HStack(spacing: 0) {
            sidePanel
            VStack(alignment: .leading, spacing: 0) {
                Text(session.title)
                    .font(.system(size: 18, weight: .semibold))
                    .padding(.horizontal, 20)
                    .padding(.top, 22)
                    .padding(.bottom, 12)

                if choosing, !session.message.isEmpty {
                    MarkdownText(session.message)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 20)
                        .padding(.bottom, 12)
                }

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(session.items) { item in
                            ItemRow(item: item, isChecked: checkBinding(for: item))
                            if item.id != session.items.last?.id { Divider().padding(.leading, 64) }
                        }
                    }
                    .padding(.horizontal, 12)
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
                .padding(.horizontal, 20)

                Group {
                    if choosing {
                        if let countdown = session.countdown {
                            CountdownView(countdown: countdown)
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 6) {
                            SessionProgressBar(progress: session.progress)
                            Text(session.progress.text)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 14)

                // One row when it fits; longer translations move the menu (or help button)
                // onto its own row above the buttons, both right-aligned, then stack the buttons,
                // rather than squeezing them.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        footerLeading
                        Spacer(minLength: 10)
                        footerButtons
                    }
                    VStack(alignment: .trailing, spacing: 12) {
                        footerLeading
                        HStack(spacing: 10) { footerButtons }
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    VStack(alignment: .trailing, spacing: 12) {
                        footerLeading
                        footerButtons
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(20)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        }
        .onAppear { menuChoice = model.selection ?? session.menu?.selected ?? "" }
    }

    /// The deferral-length menu while choosing; the help button after.
    @ViewBuilder private var footerLeading: some View {
        if choosing, let menu = session.menu {
            Picker(menu.title, selection: $menuChoice) {
                ForEach(menu.options, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .fixedSize()
            .onChange(of: menuChoice) { _, value in model.selection = value }
        } else if !choosing, let help = session.help {
            HelpButton(help: help)
        }
    }

    @ViewBuilder private var footerButtons: some View {
        if choosing, let secondary = session.secondaryButton {
            Button(secondary.title) { model.onAction(.secondary) }
                .controlSize(.large)
                .disabled(!secondary.enabled)
                .fixedSize()
        }
        if let button = session.button {
            Button(primaryTitle) { model.onAction(.primary) }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(!button.enabled || (choosing && installCount == 0))
                .fixedSize()
        }
    }

    /// The row's "install now" checkbox while choosing; nil when it has none.
    private func checkBinding(for item: DialogSession.Item) -> Binding<Bool>? {
        guard choosing, item.selected != nil else { return nil }
        let id = item.id
        return Binding(
            get: { !model.deselected.contains(id) },
            set: { on in
                if on { model.deselected.remove(id) } else { model.deselected.insert(id) }
            })
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
    /// The "install now" checkbox while choosing.
    var isChecked: Binding<Bool>? = nil

    var body: some View {
        HStack(spacing: 12) {
            if let isChecked {
                Toggle("Install \(item.title) now", isOn: isChecked)
                    .toggleStyle(.checkbox)
                    .labelsHidden()
            }
            DialogIconView(spec: item.icon, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.system(size: 14, weight: .medium)).lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Text(verbatim: item.displayStatus)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .monospacedDigit()
            StatusSymbol(status: item.status, progress: item.progress)
                .frame(width: 20, height: 20)
        }
        .padding(.vertical, 10)
        .opacity(item.status == .deferred ? 0.55 : 1)
        // A row with a checkbox keeps it reachable on its own.
        .accessibilityElement(children: isChecked == nil ? .combine : .contain)
    }
}

private struct StatusSymbol: View {
    let status: DialogSession.Item.Status
    var progress: Double? = nil

    var body: some View {
        switch status {
        case .pending:
            Image(systemName: "circle.dashed").foregroundStyle(.tertiary)
        case .working:
            if let progress {
                ProgressView(value: min(max(progress, 0), 1))
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .animation(.easeOut(duration: 0.25), value: progress)
            } else {
                ProgressView().controlSize(.small)
            }
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
        case .deferred:
            Image(systemName: "clock").foregroundStyle(.secondary)
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
    private func section(_ title: LocalizedStringKey?, _ rows: [DialogSession.Help.Row]) -> some View {
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
        VStack(spacing: 0) {
            CompactHeader(session: session)
            content
        }
        .frame(width: DialogLayout.compactSize.width, height: DialogLayout.compactSize.height)
        .background(Color(nsColor: .windowBackgroundColor))
        // The title bar is hidden; the header takes its place.
        .ignoresSafeArea()
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 16) {
            DialogIconView(spec: session.icon, overlay: session.overlayIcon, size: 80)
            VStack(alignment: .leading, spacing: 6) {
                // Up to two lines, truncated rather than pushing the bar out of the window.
                MarkdownText(session.message)
                    .font(.system(size: 13))
                    .lineLimit(2)
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
        // Pinned to the top, so the content never shifts as the message changes.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// The compact window's title bar: AppTitle and the DialogIcon on the brand colors, like
/// PatcherMenu's header.
private struct CompactHeader: View {
    let session: DialogSession

    private var brandText: Color { session.branding.textColor }
    private var brandBackground: Color { session.branding.backgroundColor }

    /// Room for the window buttons, when DialogShowWindowButtons shows any.
    private var leadingInset: CGFloat { session.window.buttons.isEmpty ? 12 : 76 }

    var body: some View {
        HStack(spacing: 8) {
            DialogIconView(spec: session.branding.icon ?? session.icon, size: 22)
            Text(session.branding.appTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(brandText)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.leading, leadingInset)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, minHeight: DialogLayout.compactHeaderHeight,
               maxHeight: DialogLayout.compactHeaderHeight)
        .background(brandBackground)
    }
}

// MARK: - Blocking-app notice and prompt

struct BlockingAppView: View {
    @ObservedObject var model: DialogModel
    @State private var checked: Bool

    init(model: DialogModel) {
        self.model = model
        // Starts from the session's state without counting as a toggle.
        _checked = State(initialValue: model.checked)
    }

    private var session: DialogSession { model.session }
    private func onAction(_ action: DialogAction) { model.onAction(action) }

    private var brandText: Color { session.branding.textColor }
    private var brandBackground: Color { session.branding.backgroundColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                DialogIconView(spec: session.branding.icon, size: 30)
                Text(session.title)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(brandText)
                    .lineLimit(1)
            }
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

            if let checkbox = session.checkbox {
                Toggle(checkbox.label, isOn: $checked)
                    .toggleStyle(.checkbox)
                    .onChange(of: checked) { _, value in
                        model.checked = value
                        model.onToggle(value)
                    }
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

// MARK: - Brand colors

extension DialogSession.Branding {
    /// BrandColorFont, switching to BrandColorFontDark in dark mode when it is set.
    var textColor: Color { Self.color(textColorHex, dark: textColorDarkHex, fallback: .white) }

    /// BrandColorBackground, switching to BrandColorBackgroundDark in dark mode when it is set.
    var backgroundColor: Color { Self.color(backgroundColorHex, dark: backgroundColorDarkHex, fallback: .systemBlue) }

    private static func color(_ lightHex: String, dark darkHex: String?, fallback: NSColor) -> Color {
        let light = NSColor(hex: lightHex) ?? fallback
        guard let darkHex, let dark = NSColor(hex: darkHex) else { return Color(nsColor: light) }
        return Color(nsColor: .appearanceAware(light: light, dark: dark))
    }
}
