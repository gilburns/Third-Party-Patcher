//
//  DialogWindow.swift
//  PatcherNotifier
//
//  One on-screen window for a DialogSession: size, position, level, blur, window
//  buttons and the quit key. Content is DialogRootView.
//

import AppKit
import SwiftUI

/// Accepts key focus without a visible title bar, and handles the quit key.
private final class DialogNSWindow: NSWindow {
    var onQuitKey: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let key   = event.charactersIgnoringModifiers?.lowercased()
        // Cmd+Shift+X dismisses (same quit key patcher gave swiftDialog); Cmd+Q is blocked.
        if flags == [.command, .shift], key == "x" {
            onQuitKey?()
            return true
        }
        if flags == .command, key == "q" { return true }
        return super.performKeyEquivalent(with: event)
    }
}

final class DialogWindow: NSObject, NSWindowDelegate {

    let id: String
    private let model: DialogModel
    /// The session as last drawn.
    var session: DialogSession { model.session }
    private let window: DialogNSWindow
    private var blurWindows: [NSWindow] = []
    /// The action, with the menu choice (primary) or checkbox state (secondary) when the
    /// window has one.
    private let onAction: (DialogAction, String?) -> Void

    init(session: DialogSession, onToggle: @escaping (Bool) -> Void = { _ in },
         onAction: @escaping (DialogAction, String?) -> Void) {
        self.id          = session.id
        self.onAction    = onAction
        self.model       = DialogModel(session: session)

        window = DialogNSWindow(contentRect: NSRect(origin: .zero, size: Self.contentSize(for: session)),
                                styleMask: Self.styleMask(for: session), backing: .buffered, defer: false)
        super.init()

        model.onAction   = { [weak self] action in
            guard let self else { return }
            let choosing = self.model.session.phase == .choosing
            switch action {
            case .primary where choosing:
                self.onAction(action, self.model.choice.encoded())
            case .secondary where choosing:
                self.onAction(action, self.model.session.menu == nil ? nil : self.model.selection)
            case .primary:
                self.onAction(action, self.model.selection)
            case .secondary:
                let state = self.model.session.checkbox == nil ? nil : DialogSession.Checkbox.value(self.model.checked)
                self.onAction(action, state)
            case .dismissed:
                self.onAction(action, nil)
            }
        }
        model.onToggle   = onToggle
        window.onQuitKey = { [weak self] in self?.onAction(.dismissed, nil) }

        window.title = session.branding.appTitle
        window.isMovable = session.window.movable
        window.isMovableByWindowBackground = session.window.movable
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.delegate = self
        let host = NSHostingView(rootView: DialogRootView(model: model))
        // The prompts and the large apply window keep the size DialogLayout gives. Left to
        // itself, the hosting view resizes the window from its content: room for the hidden
        // title bar, or the apply window's wrapped message.
        if session.kind.expectsResponse || session.kind == .applyList { host.sizingOptions = [] }
        window.contentView = host
        applyChrome(for: session)
        window.setFrame(NSRect(origin: .zero, size: frameSize(for: Self.contentSize(for: session))), display: false)
        window.level = Self.level(for: session)
    }

    // MARK: Chrome

    /// The compact and progress windows match swiftDialog's mini style: AppTitle in a
    /// normal title bar. The rest draw their own title or branded banner, so the title bar
    /// is hidden and transparent.
    private static func hasOwnTitleBar(_ session: DialogSession) -> Bool {
        session.kind == .applyCompact || session.kind == .progress
    }

    private static func styleMask(for session: DialogSession) -> NSWindow.StyleMask {
        let buttons = Set(session.window.buttons)
        var style: NSWindow.StyleMask = hasOwnTitleBar(session) ? [.titled] : [.titled, .fullSizeContentView]
        if buttons.contains("close") { style.insert(.closable) }
        if buttons.contains("min")   { style.insert(.miniaturizable) }
        if buttons.contains("max")   { style.insert(.resizable) }
        return style
    }

    private func applyChrome(for session: DialogSession) {
        let ownTitleBar = Self.hasOwnTitleBar(session)
        let buttons     = Set(session.window.buttons)
        window.titleVisibility            = ownTitleBar ? .visible : .hidden
        window.titlebarAppearsTransparent = !ownTitleBar
        window.standardWindowButton(.closeButton)?.isHidden       = !buttons.contains("close")
        window.standardWindowButton(.miniaturizeButton)?.isHidden = !buttons.contains("min")
        window.standardWindowButton(.zoomButton)?.isHidden        = !buttons.contains("max")
    }

    private static func level(for session: DialogSession) -> NSWindow.Level {
        if session.awaitsResponse {
            // Above the apply window and its blur: the window needs an answer.
            return NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 2)
        } else if session.window.blurScreen {
            return NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        } else {
            return session.window.onTop ? .floating : .normal
        }
    }

    /// The window frame for a content size. A titled window's frame normally adds the title
    /// bar's height, even when the title bar is hidden. The prompts draw from the window's
    /// top edge, so their frame is exactly the layout size; otherwise the extra height ends
    /// up as blank space below the buttons.
    private func frameSize(for content: CGSize) -> CGSize {
        if model.session.kind.expectsResponse { return content }
        return window.frameRect(forContentRect: NSRect(origin: .zero, size: content)).size
    }

    private static func contentSize(for session: DialogSession) -> CGSize {
        switch session.kind {
        case .applyList:
            return CGSize(width: DialogLayout.listWidth, height: DialogLayout.listHeight(itemCount: session.items.count))
        case .applyCompact, .progress:
            return DialogLayout.compactSize
        case .blockingPrompt:
            return DialogLayout.promptSize
        case .blockingNotice:
            return DialogLayout.noticeSize
        }
    }

    func show() {
        let session = model.session
        let screen  = NSScreen.main ?? NSScreen.screens.first
        if let screen {
            window.setFrameOrigin(Self.origin(for: window.frame.size, position: session.window.position, on: screen))
        }
        if session.window.blurScreen { showBlur() }
        if session.window.hideOtherApps { NSApp.hideOtherApplications(nil) }

        // Progress windows are shown on top without taking focus, so the user can keep
        // working while updates apply. The large window comes forward once it's complete
        // and Done needs a click; prompts come forward at once.
        window.orderFrontRegardless()
        if session.awaitsResponse { bringForward() }
    }

    func update(_ session: DialogSession) {
        let previous = model.session
        guard session != previous else { return }
        model.session = session
        window.title = session.branding.appTitle
        window.level = Self.level(for: session)

        if previous.window.blurScreen, !session.window.blurScreen { hideBlur() }

        if session.kind != previous.kind {
            // The apply window shrinking to the compact window after choosing: restyle it,
            // and move it to the compact window's position as it shrinks.
            window.styleMask = Self.styleMask(for: session)
            applyChrome(for: session)
            let size = frameSize(for: Self.contentSize(for: session))
            if let screen = window.screen ?? NSScreen.main {
                let origin = Self.origin(for: size, position: session.window.position, on: screen)
                window.setFrame(NSRect(origin: origin, size: size), display: true, animate: true)
            }
            return
        }

        let size = frameSize(for: Self.contentSize(for: session))
        if window.frame.size != size {
            // Grow or shrink from the top edge so the window doesn't jump.
            let frame = NSRect(x: window.frame.minX, y: window.frame.maxY - size.height,
                               width: size.width, height: size.height)
            window.setFrame(frame, display: true, animate: false)
        }
        if session.kind == .applyList, session.phase == .complete, previous.phase != .complete {
            bringForward()
        }
    }

    func close() {
        window.orderOut(nil)
        window.close()
        hideBlur()
    }

    private func hideBlur() {
        for blur in blurWindows { blur.orderOut(nil); blur.close() }
        blurWindows = []
    }

    private func bringForward() {
        NSApp.activate()
        window.orderFrontRegardless()
        window.makeKey()
    }

    // MARK: Blur

    private func showBlur() {
        for screen in NSScreen.screens {
            let blur = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false, screen: screen)
            blur.setFrame(screen.frame, display: false)
            blur.level = .floating
            blur.isOpaque = false
            blur.backgroundColor = .clear
            blur.isReleasedWhenClosed = false
            blur.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let effect = NSVisualEffectView()
            effect.material = .fullScreenUI
            effect.blendingMode = .behindWindow
            effect.state = .active
            blur.contentView = effect
            blur.orderFrontRegardless()
            blurWindows.append(blur)
        }
    }

    // MARK: Position

    /// topleft | left | bottomleft | top | center | bottom | topright | right | bottomright,
    /// or "x,y": the window's top-left corner, in points from the screen's top-left (as
    /// swiftDialog's `--position x,y` did). Coordinates are kept inside the visible area.
    static func origin(for size: CGSize, position: String, on screen: NSScreen) -> NSPoint {
        let area   = screen.visibleFrame
        let margin: CGFloat = 20
        let p      = position.lowercased().trimmingCharacters(in: .whitespaces)

        let parts = p.split(separator: ",").map { Double($0.trimmingCharacters(in: .whitespaces)) }
        if parts.count == 2, let px = parts[0], let py = parts[1] {
            let x = min(max(screen.frame.minX + px, area.minX), area.maxX - size.width)
            let y = min(max(screen.frame.maxY - py - size.height, area.minY), area.maxY - size.height)
            return NSPoint(x: x.rounded(), y: y.rounded())
        }

        let x: CGFloat
        if p.hasSuffix("left")       { x = area.minX + margin }
        else if p.hasSuffix("right") { x = area.maxX - size.width - margin }
        else                         { x = area.midX - size.width / 2 }

        let y: CGFloat
        if p.hasPrefix("top")         { y = area.maxY - size.height - margin }
        else if p.hasPrefix("bottom") { y = area.minY + margin }
        else                          { y = area.midY - size.height / 2 }

        return NSPoint(x: x.rounded(), y: y.rounded())
    }

    // MARK: NSWindowDelegate

    /// The title-bar close button (only shown when DialogShowWindowButtons includes it).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        onAction(.dismissed, nil)
        return false
    }
}
