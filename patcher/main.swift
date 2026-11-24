//
//  main.swift
//  patcher
//
//  Created by Gil Burns on 3/9/25.
//

import Foundation
import ArgumentParser

// MARK: - SIGTERM handling
//
// shutdownRequested (PatcherCore.swift) is set here and checked between
// installations in the apply loop.

private func installSigtermHandler() {
    signal(SIGTERM, SIG_IGN)   // suppress default termination; we handle it below
    let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    src.setEventHandler {
        Logger.log("⚠️ SIGTERM received — will stop after current installation completes.")
        shutdownRequested = true
    }
    src.resume()
    _ = src
}

// MARK: - Run the application
installSigtermHandler()
Patcher.main()
