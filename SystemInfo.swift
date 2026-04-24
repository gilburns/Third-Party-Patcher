//
//  SystemInfo.swift
//  patcher
//
//  Modified by Gil Burns on 4/18/26.
//

import Foundation
import SystemConfiguration

// MARK: - Console user helper
public var consoleUserInfo: (username: String, userID: String) {
    // We need the console user, not the process owner so NSUserName() won't work for our needs when outset runs as root
    var uid: uid_t = 0
    if let consoleUser = SCDynamicStoreCopyConsoleUser(nil, &uid, nil) as? String {
        return (consoleUser, "\(uid)")
    } else {
        return ("", "")
    }
}

public var consoleUserUID: uid_t? {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) != nil else { return nil }
    return uid
}

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

public var installomatorVersion: String {
    (try? String(contentsOf: AppConstants.installomatorVersionFileURL, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown"
}

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

public var osVersion: String {
    // Returns the OS version
    let osVersion = ProcessInfo().operatingSystemVersion
    let version = "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
    return version
}

public var osBuildVersion: String {
    // Returns the current OS build from sysctl
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


public var deviceSerialNumber: String {
    // Returns the current devices serial number
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

public var marketingModel: String {
    return !marketingModelARM.isEmpty ? marketingModelARM : marketingModelIntel
}

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

public var deviceHardwareModel: String {
    // Returns the current devices hardware model from sysctl
    var size = 0
    sysctlbyname("hw.model", nil, &size, nil, 0)
    var model = [CChar](repeating: 0, count: size)
    sysctlbyname("hw.model", &model, &size, nil, 0)
    return String(cString: model)
}

public extension ProcessInfo {
    var osName: String {
        let version = self.operatingSystemVersion
        switch version.majorVersion {
        case 26: return "Tahoe"
        case 15: return "Sequoia"
        case 14: return "Sonoma"
        case 13: return "Ventura"
        case 12: return "Monterey"
        case 11: return "Big Sur"
        case 10: break
        default: return "macOS \(version.majorVersion)"
        }
        return "macOS \(version.majorVersion)"
    }
}

public extension ProcessInfo {
    var osVersionString: String {
        let version = self.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }
}
