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
            menuBarIcon
                .help(viewModel.preferences.appTitle)
        }
        .menuBarExtraStyle(.window)
        .commands {
            CommandGroup(replacing: .appTermination) { }
        }
    }


    /// Resolves the menu bar icon from preferences:
    /// - Empty string → built-in symbol, switches between outline/filled to indicate pending state.
    /// - Path (starts with / or ~) → PNG loaded from disk; pending state shown as an orange dot badge.
    /// - Anything else → treated as an SF Symbol name; pending state shown as an orange dot badge.
    @ViewBuilder
    private var menuBarIcon: some View {
        let icon = viewModel.preferences.menuBarIcon
        let hasPending = viewModel.hasPendingPatches

        if icon.isEmpty {
            Image(systemName: hasPending
                  ? "arrow.triangle.2.circlepath.circle.fill"
                  : "arrow.triangle.2.circlepath")
        } else if icon.hasPrefix("/") || icon.hasPrefix("~") {
            let path = (icon as NSString).expandingTildeInPath
            ZStack(alignment: .topTrailing) {
                if let nsImage = NSImage(contentsOfFile: path) {
                    Image(nsImage: nsImage)
                        .renderingMode(.template)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: "arrow.triangle.2.circlepath")
                }
                if hasPending {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .offset(x: 3, y: -3)
                }
            }
        } else {
            ZStack(alignment: .topTrailing) {
                Image(systemName: icon)
                if hasPending {
                    Circle()
                        .fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .offset(x: 3, y: -3)
                }
            }
        }
    }
}
