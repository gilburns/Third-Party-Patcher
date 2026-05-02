//
//  AvailableSoftwareApp.swift
//  Available Software
//
//  Created by Gil Burns on 4/25/26.
//

import SwiftUI

@main
struct AvailableSoftwareApp: App {
    @StateObject private var viewModel = AvailableSoftwareViewModel()

    init() {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup {
            CatalogView()
                .environmentObject(viewModel)
        }
        .defaultSize(width: 720, height: 520)
    }
}
