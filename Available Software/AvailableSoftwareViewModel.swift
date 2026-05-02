//
//  AvailableSoftwareViewModel.swift
//  Available Software
//
//  Created by Gil Burns on 4/25/26.
//

import Foundation
import AppKit
import Combine

@MainActor
final class AvailableSoftwareViewModel: ObservableObject {

    @Published var preferences = Preferences()
    @Published var activePhase: String?
    @Published var activeLabel: String?
    @Published var activeStatus: String?

    private var xpcConnection: NSXPCConnection?
    private var configDirWatcher: DispatchSourceFileSystemObject?
    private var configDirFD: Int32 = -1

    init() {
        startConfigDirWatch()
    }

    deinit {
        configDirWatcher?.cancel()
        if configDirFD >= 0 { close(configDirFD) }
    }

    // MARK: - Config directory watcher

    private func startConfigDirWatch() {
        let path = AppConstants.patcherConfigFolderURL.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        configDirFD = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: .write,
            queue: DispatchQueue.global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in self?.reloadActivePhase() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        configDirWatcher = source

        reloadActivePhase()
    }

    private func reloadActivePhase() {
        let url = AppConstants.patcherConfigFolderURL.appendingPathComponent("active_phase.json")
        guard let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let phase = dict["phase"] as? String
        else {
            activePhase = nil
            activeLabel = nil
            activeStatus = nil
            return
        }
        activePhase = phase
        activeLabel = dict["label"] as? String
        activeStatus = dict["status"] as? String
    }

    // MARK: - XPC

    func installLabel(_ label: String) {
        if xpcConnection == nil { setupXPCConnection() }
        guard let proxy = xpcConnection?.remoteObjectProxyWithErrorHandler({ [weak self] error in
            NSLog("AvailableSoftware XPC error: %@", error.localizedDescription)
            Task { @MainActor [weak self] in self?.xpcConnection = nil }
        }) as? PatcherXPCProtocol else {
            NSLog("AvailableSoftware XPC: failed to obtain proxy for installLabel '\(label)'")
            return
        }
        proxy.installLabel(label) { success, message in
            NSLog("AvailableSoftware XPC installLabel reply: success=%d message=%@", success, message)
        }
    }

    private func setupXPCConnection() {
        let conn = NSXPCConnection(machServiceName: AppConstants.patcherXPCServiceName, options: .privileged)
        conn.remoteObjectInterface = NSXPCInterface(with: PatcherXPCProtocol.self)
        conn.invalidationHandler = { NSLog("AvailableSoftware XPC connection invalidated") }
        conn.interruptionHandler = { NSLog("AvailableSoftware XPC connection interrupted") }
        conn.resume()
        xpcConnection = conn
    }
}
