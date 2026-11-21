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
    private let window: DialogNSWindow
    private var blurWindows: [NSWindow] = []
    private let onUserClose: () -> Void

    init(session: DialogSession, onUserClose: @escaping () -> Void) {
        self.id          = session.id
        self.onUserClose = onUserClose
        self.model       = DialogModel(session: session)

        let buttons = Set(session.window.buttons)
        // The large window draws its own title over a transparent title bar. The compact
        // and progress windows match swiftDialog's mini style: AppTitle in a normal title bar.
        let ownTitleBar = session.kind != .applyList
        var style: NSWindow.StyleMask = ownTitleBar ? [.titled] : [.titled, .fullSizeContentView]
        if buttons.contains("close") { style.insert(.closable) }
        if buttons.contains("min")   { style.insert(.miniaturizable) }
        if buttons.contains("max")   { style.insert(.resizable) }

        window = DialogNSWindow(contentRect: NSRect(origin: .zero, size: Self.contentSize(for: session)),
                                styleMask: style, backing: .buffered, defer: false)
        super.init()

        model.onDone = { [weak self] in self?.onUserClose() }
        window.onQuitKey = { [weak self] in self?.onUserClose() }

        window.title = session.branding.appTitle
        window.titleVisibility = ownTitleBar ? .visible : .hidden
        window.titlebarAppearsTransparent = !ownTitleBar
        window.standardWindowButton(.closeButton)?.isHidden       = !buttons.contains("close")
        window.standardWindowButton(.miniaturizeButton)?.isHidden = !buttons.contains("min")
        window.standardWindowButton(.zoomButton)?.isHidden        = !buttons.contains("max")
        window.isMovable = session.window.movable
        window.isMovableByWindowBackground = session.window.movable
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.delegate = self
        window.contentView = NSHostingView(rootView: DialogRootView(model: model))
        window.setContentSize(Self.contentSize(for: session))

        if session.window.blurScreen {
            window.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)
        } else {
            window.level = session.window.onTop ? .floating : .normal
        }
    }

    private static func contentSize(for session: DialogSession) -> CGSize {
        switch session.kind {
        case .applyList:
            return CGSize(width: DialogLayout.listWidth, height: DialogLayout.listHeight(itemCount: session.items.count))
        case .applyCompact, .progress:
            return DialogLayout.compactSize
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

        // Shown on top without taking focus, so the user can keep working while updates
        // apply. The large window comes forward once it's complete and Done needs a click.
        window.orderFrontRegardless()
    }

    func update(_ session: DialogSession) {
        let previous = model.session
        guard session != previous else { return }
        model.session = session
        window.title = session.branding.appTitle

        let size = Self.contentSize(for: session)
        if window.contentLayoutRect.size != size {
            // Grow or shrink from the top edge so the window doesn't jump.
            var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
            frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
            window.setFrame(frame, display: true, animate: false)
        }
        if session.kind == .applyList, session.phase == .complete, previous.phase != .complete {
            bringForward()
        }
    }

    func close() {
        window.orderOut(nil)
        window.close()
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

    /// topleft | left | bottomleft | top | center | bottom | topright | right | bottomright
    static func origin(for size: CGSize, position: String, on screen: NSScreen) -> NSPoint {
        let area   = screen.visibleFrame
        let margin: CGFloat = 20
        let p      = position.lowercased()

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
        onUserClose()
        return false
    }
}
