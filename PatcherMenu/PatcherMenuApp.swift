//
//  PatcherMenuApp.swift
//  PatcherMenu
//
//  Created by Gil Burns on 4/22/26.
//

import SwiftUI
import AppKit

@main
struct PatcherMenuApp: App {
    @StateObject private var viewModel = PatcherMenuViewModel()

    var body: some Scene {
        MenuBarExtra {
            MenuStatusView()
                .environmentObject(viewModel)
        } label: {
            // MenuBarIconView is a proper View with @ObservedObject so it re-renders
            // whenever stagedPatches or preferences change — unlike a @ViewBuilder on
            // the App struct, which does not react to @StateObject updates.
            MenuBarIconView(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appTermination) { }
        }
    }
}


/// Reactive menu bar icon.
///
/// Icon behaviour (controlled by the MenuBarIcon preference):
///   - Empty      → built-in SF Symbol; switches between two symbols to signal pending state.
///   - Path       → image file scaled to 16×16; pending state shown as an orange dot badge.
///   - SF Symbol  → named symbol; pending state shown as an orange dot badge.
///
/// All rendering goes through ImageRenderer so the label receives a single pre-composited
/// NSImage. ZStack and Shape views are unreliable when used directly inside MenuBarExtra labels.
private struct MenuBarIconView: View {
    @ObservedObject var viewModel: PatcherMenuViewModel

    private var icon: String { viewModel.preferences.menuBarIcon }
    private var hasPending: Bool { viewModel.hasPendingPatches }

    var body: some View {
        Image(nsImage: getMenuIcon())
            .help(viewModel.preferences.appTitle)
    }

    private func getMenuIcon() -> NSImage {
        let renderer = ImageRenderer(content: iconContent())
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2.0
        let result = renderer.nsImage ?? NSImage()
        // Symbol-only case has no badge, so template rendering is safe and gives
        // automatic light/dark adaptation. Badge cases must stay non-template to
        // preserve the orange color.
        result.isTemplate = !icon.hasPrefix("/") && !icon.hasPrefix("~")
        return result
    }

    @ViewBuilder
    private func iconContent() -> some View {
        if icon.isEmpty {
            // Switch between two symbols to convey pending state — no badge needed.
            Image(systemName: hasPending
                  ? "plus.arrow.trianglehead.clockwise"
                  : "checkmark.arrow.trianglehead.clockwise")
                .resizable()
                .scaledToFit()
                .frame(width: 16, height: 16)

        } else if icon.hasPrefix("/") || icon.hasPrefix("~") {
            // Custom image file.
            let path = (icon as NSString).expandingTildeInPath
            ZStack(alignment: .topTrailing) {
                if let image = NSImage(contentsOfFile: path) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "questionmark.square")
                        .resizable()
                        .scaledToFit()
                }
                if hasPending {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 5, height: 5)
                }
            }
            .frame(width: 16, height: 16)

        } else {
            // Named SF Symbol with optional badge.
            ZStack(alignment: .topTrailing) {
                Image(systemName: icon)
                    .resizable()
                    .scaledToFit()
                if hasPending {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 5, height: 5)
                }
            }
            .frame(width: 16, height: 16)
        }
    }
}

