//
//  SystemInfo.swift
//  patcher
//
//  Modified by Gil Burns on 4/18/26.
//

import Foundation
import SystemConfiguration

// MARK: - Console user helper

/// Returns the username and numeric UID of the user currently logged in at the console.
/// Uses `SCDynamicStoreCopyConsoleUser` rather than `NSUserName()` because patcher runs
/// as root — `NSUserName()` would return "root", not the interactive user.
/// Returns ("", "") when no user is logged in.
public var consoleUserInfo: (username: String, userID: String) {
    var uid: uid_t = 0
    if let consoleUser = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as? String {
        return (consoleUser, "\(uid)")
    } else {
        return ("", "")
    }
}

/// Returns the UID of the user currently at the console, or nil when no one is logged in.
/// Used to launch swiftDialog in the correct user session via `launchctl asuser`.
public var consoleUserUID: uid_t? {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) != nil else { return nil }
    return uid
}

/// Returns the hardware serial number by parsing `ioreg` output.
/// Used in the swiftDialog help panel so support staff can identify the machine.
/// Returns "Unknown" if the IOPlatformSerialNumber key is not found.
public var macSerialNumber: String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/sbin/ioreg")
    p.arguments = ["-rd1", "-c", "IOPlatformExpertDevice"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError  = Pipe()
    try? p.run()
    p.waitUntilExit()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard let range = output.range(of: "\"IOPlatformSerialNumber\" = \"") else { return "Unknown" }
    let start = range.upperBound
    guard let end = output[start...].firstIndex(of: "\"") else { return "Unknown" }
    return String(output[start..<end])
}

/// Returns the OS version and build number as a single string, e.g. "14.5.0 (23F79)".
/// Combines `ProcessInfo` for the version triple and `sw_vers -buildVersion` for the build.
public var macOSVersion: String {
    let v = ProcessInfo.processInfo.operatingSystemVersion
    let version = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/sw_vers")
    p.arguments = ["-buildVersion"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError  = Pipe()
    try? p.run()
    p.waitUntilExit()
    let build = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown"
    return "\(version) (\(build))"
}

/// Returns the Installomator version string read from the local version file.
/// Returns "Unknown" when the file is absent (Installomator not yet installed).
public var installomatorVersion: String {
    (try? String(contentsOf: AppConstants.installomatorVersionFileURL, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown"
}

/// Returns the installed swiftDialog version by running `dialog --version`.
/// Returns "Unknown" when swiftDialog is not installed or the binary cannot be executed.
public var swiftDialogVersion: String {
    let p = Process()
    p.executableURL = AppConstants.swiftDialogBinaryURL
    p.arguments = ["--version"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError  = Pipe()
    try? p.run()
    p.waitUntilExit()
    return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown"
}

/// Returns the OS version triple as a plain string, e.g. "14.5.0".
/// Unlike `macOSVersion`, this does not include the build number.
public var osVersion: String {
    let osVersion = ProcessInfo().operatingSystemVersion
    let version = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
    return version
}

/// Returns the OS build string (e.g. "23F79") read directly from `kern.osversion` via sysctl.
/// Unlike `macOSVersion`, this returns only the build identifier with no version prefix.
public var osBuildVersion: String {
    var size = 0
    sysctlbyname("kern.osversion", nil, &size, nil, 0)
    var osversion = [CChar](repeating: 0, count: size)
    sysctlbyname("kern.osversion", &osversion, &size, nil, 0)
    return String(cString: osversion)
}

/// True when the Mac has an internal battery (i.e. is a laptop), regardless
/// of current power source.
public var hasBattery: Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
    p.arguments = ["-g", "batt"]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError  = Pipe()
    try? p.run()
    p.waitUntilExit()
    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return output.contains("InternalBattery")
}

/// Returns the hardware serial number via IOKit directly.
/// Prefer `macSerialNumber` for display purposes; this variant is kept for compatibility
/// with callers that already depend on the IOKit path.
public var deviceSerialNumber: String {
    let platformExpert = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice") )
      guard platformExpert > 0 else {
        return "Serial Unknown"
      }
      guard let serialNumber = (IORegistryEntryCreateCFProperty(platformExpert, kIOPlatformSerialNumberKey as CFString, kCFAllocatorDefault, 0).takeUnretainedValue() as? String)?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines) else {
        return "Serial Unknown"
      }
      IOObjectRelease(platformExpert)
      return serialNumber
}

/// Returns the human-readable marketing model name, e.g. "MacBook Pro (14-inch, M3 Pro)".
/// Tries the Apple Silicon IORegistry path first; falls back to the Intel private-framework
/// path so both architectures are covered by a single call site.
public var marketingModel: String {
    return !marketingModelARM.isEmpty ? marketingModelARM : marketingModelIntel
}

/// Returns the marketing model name for Apple Silicon Macs via the IORegistry `product-description` key.
/// Returns an empty string on Intel Macs, which have no `/AppleARMPE/product` node.
public var marketingModelARM: String {
    let appleSiliconProduct = IORegistryEntryFromPath(kIOMainPortDefault, "IOService:/AppleARMPE/product")
        let cfKeyValue = IORegistryEntryCreateCFProperty(appleSiliconProduct, "product-description" as CFString, kCFAllocatorDefault, 0)
        IOObjectRelease(appleSiliconProduct)
        let keyValue: AnyObject? = cfKeyValue?.takeUnretainedValue()
        if keyValue != nil, let data = keyValue as? Data {
            return String(data: data, encoding: String.Encoding.utf8)?.trimmingCharacters(in: CharacterSet(["\0"])) ?? ""
        }
        return ""
}

/// Returns the marketing model name for Intel Macs by looking up `hw.model` in
/// `SIMachineAttributes.plist` inside the ServerInformation private framework.
/// Falls back to the raw hardware model identifier (e.g. "MacBookPro18,3") if the
/// plist is absent or the identifier has no entry — which can happen on newer hardware
/// before Apple updates the private framework.
public var marketingModelIntel: String {
    guard let locale = Locale.current.language.languageCode?.identifier else { return "en" }

    let modelIdentifier = deviceHardwareModel

    var path = "/System/Library/PrivateFrameworks/ServerInformation.framework/Versions/A/Resources/"
    path += locale + ".lproj"
    path += "/SIMachineAttributes.plist"

    if let fileData = FileManager.default.contents(atPath: path) {
        if let plistContents = try? PropertyListSerialization.propertyList(from: fileData, format: nil)
            as? [String: Any] {
            if let contents = plistContents[modelIdentifier] as? [String: Any],
               let localizable = contents["_LOCALIZABLE_"] as? [String: String] {
                let marketingModel = localizable["marketingModel"] ?? modelIdentifier
                return marketingModel
            }
        }
    }
    return modelIdentifier
}

/// Returns the hardware model identifier (e.g. "MacBookPro18,3") from `hw.model` via sysctl.
public var deviceHardwareModel: String {
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var model = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &model, &size, nil, 0)
    return String(cString: model)
}

/// Maps the macOS major version number to its marketing name.
/// Returns "macOS N" for any version not explicitly listed, so forward compatibility
/// degrades gracefully rather than returning an empty string.
public extension ProcessInfo {
    var osName: String {
        let version = self.operatingSystemVersion
        switch version.majorVersion {
        case 27: return "vNext"
        case 26: return "Tahoe"
        case 15: return "Sequoia"
        case 14: return "Sonoma"
        default: return "macOS \(version.majorVersion)"
        }
    }
}

/// Returns the OS version triple as a plain "major.minor.patch" string.
public extension ProcessInfo {
    var osVersionString: String {
        let version = self.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
