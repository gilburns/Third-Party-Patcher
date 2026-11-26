//
//  PowerStatus.swift
//  patcher
//
//  Form factor (laptop vs desktop), current power source, and battery charge,
//  read from IOKit's power-source API. The scheduler uses this to decide whether
//  a phase may run while the Mac is on battery (BatteryAllowedPhases /
//  BatteryMinimumPercent).
//

import Foundation
import IOKit.ps

// MARK: - Battery-gated phases

/// Scheduler phases that can be restricted while running on battery power.
/// Raw values are the tokens admins use in the `BatteryAllowedPhases` preference.
/// `scan` covers both the full scan and the light scan.
enum BatteryGatedPhase: String, CaseIterable, Comparable {
    case scan, check, stage, apply

    static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

// MARK: - Power status

struct PowerStatus: Equatable {

    /// What is currently powering the Mac.
    enum Source: String {
        case ac      = "AC"
        case battery = "Battery"
        case ups     = "UPS"
    }

    /// True when the Mac has an internal battery (a laptop).
    let hasInternalBattery: Bool
    /// The source currently providing power.
    let source: Source
    /// Charge (0–100) of the battery providing power, or of the internal battery when on AC.
    /// nil when no battery is present or the charge can't be read.
    let batteryPercent: Int?

    var formFactor: String { hasInternalBattery ? "laptop" : "desktop" }

    /// True when running from the internal battery or from a UPS during a power outage.
    var isOnBattery: Bool { source != .ac }

    /// One-line description for logs and status output,
    /// e.g. "laptop, on battery (42%)" or "desktop, on AC power".
    var summary: String {
        let pct = batteryPercent.map { " (\($0)%)" } ?? ""
        switch source {
        case .ac:      return "\(formFactor), on AC power\(pct)"
        case .battery: return "\(formFactor), on battery\(pct)"
        case .ups:     return "\(formFactor), on UPS battery\(pct)"
        }
    }

    // MARK: Gating decision

    /// Returns why `phase` must not run under this power state, or nil when it may run.
    /// On AC power nothing is blocked. On battery, the phase must be listed in
    /// `allowedOnBattery`, and the charge must be at or above `minimumPercent`
    /// (0 disables the floor). An unreadable charge does not block.
    func blockReason(for phase: BatteryGatedPhase,
                     allowedOnBattery: Set<BatteryGatedPhase>,
                     minimumPercent: Int) -> String? {
        guard isOnBattery else { return nil }
        guard allowedOnBattery.contains(phase) else {
            return "\(summary); '\(phase.rawValue)' is not in BatteryAllowedPhases"
        }
        if minimumPercent > 0, let pct = batteryPercent, pct < minimumPercent {
            return "\(summary); below BatteryMinimumPercent (\(minimumPercent)%)"
        }
        return nil
    }

    // MARK: Reading the current state

    /// Reads the current power state from IOKit. Works from a root daemon.
    /// Falls back to "desktop on AC" when the power-source info can't be read,
    /// so a read failure never blocks patching.
    static func current() -> PowerStatus {
        let fallback = PowerStatus(hasInternalBattery: false, source: .ac, batteryPercent: nil)
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return fallback }

        let descriptions: [[String: Any]] = list.compactMap {
            IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any]
        }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        return from(descriptions: descriptions, providingType: providing)
    }

    /// Builds a status from power-source description dictionaries and the providing
    /// power-source type ("AC Power", "Battery Power", "UPS Power"). Split out from
    /// `current()` so it can be tested with canned IOKit data.
    static func from(descriptions: [[String: Any]], providingType: String?) -> PowerStatus {
        func isType(_ d: [String: Any], _ type: String) -> Bool {
            (d[kIOPSTypeKey] as? String) == type && (d[kIOPSIsPresentKey] as? Bool ?? true)
        }
        let internalBattery = descriptions.first { isType($0, kIOPSInternalBatteryType) }
        let ups             = descriptions.first { isType($0, kIOPSUPSType) }

        let source: Source
        switch providingType ?? "" {
        case kIOPMBatteryPowerKey: source = .battery
        case kIOPMUPSPowerKey:     source = .ups
        default:                   source = .ac
        }

        // Report the charge of whatever is powering the Mac; on AC, the internal battery's.
        let chargeSource = source == .ups ? ups : internalBattery
        return PowerStatus(hasInternalBattery: internalBattery != nil,
                           source: source,
                           batteryPercent: chargeSource.flatMap(percent(of:)))
    }

    /// Charge as a 0–100 percentage. On Apple silicon "Current Capacity" is already a
    /// percentage with "Max Capacity" 100; on Intel both may be in mAh, so divide.
    private static func percent(of description: [String: Any]) -> Int? {
        guard let current = description[kIOPSCurrentCapacityKey] as? Int,
              let max = description[kIOPSMaxCapacityKey] as? Int, max > 0 else { return nil }
        return Swift.min(100, Swift.max(0, Int((Double(current) / Double(max) * 100).rounded())))
    }
}
