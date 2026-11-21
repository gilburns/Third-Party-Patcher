//
//  PatcherNotifierApp.swift
//  PatcherNotifier
//
//  Created by Gil Burns on 9/26/26.
//
//  Agent that posts patcher events to Notification Center and shows patcher's windows.
//  Launched by its LaunchAgent (WatchPaths on the notification queue folder, and at login),
//  delivers anything pending, then quits after a short idle period.
//

import SwiftUI

@main
struct PatcherNotifierApp: App {
    @NSApplicationDelegateAdaptor(NotifierAppDelegate.self) private var appDelegate

    var body: some Scene {
        // No windows — LSUIElement agent. A Scene is still required by App.
        Settings { EmptyView() }
    }
}
