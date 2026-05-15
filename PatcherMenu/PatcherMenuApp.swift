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
///   - Empty      → built-in SF Symbol; switches between outline/filled to signal pending state.
///   - Path       → PNG from disk rendered as template; pending state shown as an orange dot badge.
///   - SF Symbol  → named symbol; pending state shown as an orange dot badge.
private struct MenuBarIconView: View {
    @ObservedObject var viewModel: PatcherMenuViewModel

    var body: some View {
        let icon       = viewModel.preferences.menuBarIcon
        let hasPending = viewModel.hasPendingPatches

        Group {
            if icon.isEmpty {
                Image(systemName: hasPending
                      ? "plus.arrow.trianglehead.clockwise"
                      : "checkmark.arrow.trianglehead.clockwise")
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
                        Image(systemName: "checkmark.arrow.trianglehead.clockwise")
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
        .help(viewModel.preferences.appTitle)
    }
}
