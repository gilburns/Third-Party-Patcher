//
//  NetworkCost.swift
//  patcher
//
//  Whether the Mac's current network connection is metered, read from the Network
//  framework. The scheduler uses this to hold back data-heavy phases (by default,
//  stage downloads) on a personal hotspot or Low Data Mode network
//  (MeteredAllowedPhases / MeteredIncludeLowDataMode / MeteredMaxBlockedDays).
//

import Foundation
import Network

// MARK: - Network cost

nonisolated struct NetworkCost: Equatable {

    /// The kind of interface the current path uses.
    enum Interface: String {
        case wifi     = "Wi-Fi"
        case cellular = "Cellular"
        case wired    = "Ethernet"
        case other    = "Other"
        case none     = "None"
    }

    /// macOS flags the path as expensive: an iPhone/iPad Personal Hotspot (over Wi-Fi,
    /// USB or Bluetooth) or a cellular link.
    let isExpensive: Bool
    /// The user turned on Low Data Mode for this network.
    let isConstrained: Bool
    let interface: Interface

    /// Used when the path can't be read in time, so a read failure never blocks patching.
    static let unknown = NetworkCost(isExpensive: false, isConstrained: false, interface: .none)

    /// True when this connection counts as metered under the given policy.
    func isMetered(includeLowDataMode: Bool) -> Bool {
        isExpensive || (includeLowDataMode && isConstrained)
    }

    /// One-line description for logs and status output,
    /// e.g. "Wi-Fi, personal hotspot" or "Ethernet, unmetered".
    var summary: String {
        var traits: [String] = []
        if isExpensive   { traits.append(interface == .cellular ? "cellular" : "personal hotspot") }
        if isConstrained { traits.append("Low Data Mode") }
        if traits.isEmpty { traits.append("unmetered") }
        return "\(interface.rawValue), \(traits.joined(separator: ", "))"
    }

    init(isExpensive: Bool, isConstrained: Bool, interface: Interface) {
        self.isExpensive   = isExpensive
        self.isConstrained = isConstrained
        self.interface     = interface
    }

    init(path: NWPath) {
        let interface: Interface
        if path.status != .satisfied           { interface = .none }
        else if path.usesInterfaceType(.wifi)  { interface = .wifi }
        else if path.usesInterfaceType(.cellular) { interface = .cellular }
        else if path.usesInterfaceType(.wiredEthernet) { interface = .wired }
        else                                   { interface = .other }
        self.init(isExpensive: path.isExpensive, isConstrained: path.isConstrained, interface: interface)
    }

    // MARK: Reading the current state

    /// Takes a one-shot snapshot of the current network path. NWPathMonitor delivers the
    /// first path almost immediately after it starts; if it doesn't within `timeout`,
    /// returns `.unknown` (unmetered). Works from a root daemon without any permission.
    static func current(timeout: TimeInterval = 2) -> NetworkCost {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var value: NetworkCost?
        }
        let box       = Box()
        let semaphore = DispatchSemaphore(value: 0)
        let monitor   = NWPathMonitor()
        monitor.pathUpdateHandler = { path in
            box.lock.lock()
            let first = box.value == nil
            if first { box.value = NetworkCost(path: path) }
            box.lock.unlock()
            if first { semaphore.signal() }
        }
        monitor.start(queue: DispatchQueue(label: "com.gilburns.patcher.networkcost"))
        _ = semaphore.wait(timeout: .now() + timeout)
        monitor.cancel()
        box.lock.lock(); defer { box.lock.unlock() }
        return box.value ?? .unknown
    }
}

// MARK: - Metered gate

/// The scheduler's decision for a due phase on the current network.
nonisolated enum MeteredGate {

    enum Decision: Equatable {
        /// Not metered, or the phase is allowed on a metered network.
        case run
        /// Blocked; wait for an unmetered network.
        case blocked(daysBlocked: Int)
        /// Blocked for `MeteredMaxBlockedDays` or longer — run on the metered network anyway.
        case override(daysBlocked: Int)
    }

    /// Decides whether `phase` may run. Starts the blocked clock (`blockedSince`) on the
    /// first block; clearing it is the caller's job (on an unmetered network, or after an
    /// overridden phase ran). `maxBlockedDays` 0 never overrides.
    static func decide(phase: GatedPhase,
                       metered: Bool,
                       allowed: Set<GatedPhase>,
                       maxBlockedDays: Int,
                       blockedSince: inout Date?,
                       now: Date) -> Decision {
        guard metered, !allowed.contains(phase) else { return .run }
        let since = blockedSince ?? now
        blockedSince = since
        let days = daysBlocked(since: since, now: now)
        if maxBlockedDays > 0 && days >= maxBlockedDays { return .override(daysBlocked: days) }
        return .blocked(daysBlocked: days)
    }

    static func daysBlocked(since: Date, now: Date) -> Int {
        max(0, Calendar.current.dateComponents([.day], from: since, to: now).day ?? 0)
    }
}

// MARK: - Paused-updates notice

/// What the metered network is holding back, for user-facing status (PatcherMenu).
/// Like `PowerPause`, it only covers downloads and installs, and only when there is
/// something for the user to wait on. Nothing is reported once the
/// `MeteredMaxBlockedDays` override has been reached, since the scheduler will run.
nonisolated struct MeteredPause: Equatable {
    let downloadsPaused: Bool
    let installsPaused: Bool
    /// Metered only because of Low Data Mode (not a hotspot or cellular link), so the
    /// user can turn Low Data Mode off for this network to continue.
    let lowDataModeOnly: Bool

    static func evaluate(network: NetworkCost,
                         includeLowDataMode: Bool,
                         allowed: Set<GatedPhase>,
                         maxBlockedDays: Int,
                         blockedSince: Date?,
                         now: Date,
                         hasUpdatesToDownload: Bool,
                         hasUpdatesToInstall: Bool) -> MeteredPause? {
        let metered = network.isMetered(includeLowDataMode: includeLowDataMode)
        func blocks(_ phase: GatedPhase) -> Bool {
            var since = blockedSince
            if case .blocked = MeteredGate.decide(phase: phase, metered: metered, allowed: allowed,
                                                  maxBlockedDays: maxBlockedDays,
                                                  blockedSince: &since, now: now) { return true }
            return false
        }
        let downloads = hasUpdatesToDownload && blocks(.stage)
        let installs  = hasUpdatesToInstall  && blocks(.apply)
        guard downloads || installs else { return nil }
        return MeteredPause(downloadsPaused: downloads,
                            installsPaused: installs,
                            lowDataModeOnly: !network.isExpensive)
    }
}
