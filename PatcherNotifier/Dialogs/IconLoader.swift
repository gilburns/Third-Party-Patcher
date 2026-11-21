//
//  IconLoader.swift
//  PatcherNotifier
//
//  Turns a dialog icon spec into an image. Specs use swiftDialog's syntax so the
//  DialogIcon / OverlayIcon values in deployed profiles keep working:
//
//    /path/to/App.app          the app's Finder icon
//    /path/to/image.png|icns   the image file
//    https://…                 downloaded once and cached
//    caution | info | stop | computer
//    SF=symbol.name,weight=bold,colour=#hex      single-colour SF Symbol
//    SF=symbol.name,palette=gray,red             palette SF Symbol (colours follow palette=)
//

import AppKit
import OSLog

final class IconLoader {

    static let shared = IconLoader()

    private var cache: [String: NSImage] = [:]
    private var inFlight: [String: Task<NSImage?, Never>] = [:]

    /// The image for `spec`, or nil when it can't be resolved.
    func image(for spec: String) async -> NSImage? {
        let spec = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !spec.isEmpty else { return nil }
        if let cached = cache[spec] { return cached }

        if let url = URL(string: spec), let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http" {
            if let task = inFlight[spec] { return await task.value }
            let task = Task<NSImage?, Never> {
                do {
                    let (data, _) = try await URLSession.shared.data(from: url)
                    return NSImage(data: data)
                } catch {
                    notifierLog.error("Icon download failed for \(spec, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    return nil
                }
            }
            inFlight[spec] = task
            let image = await task.value
            inFlight[spec] = nil
            if let image { cache[spec] = image }
            return image
        }

        let image = Self.localImage(for: spec)
        if let image { cache[spec] = image }
        return image
    }

    private static func localImage(for spec: String) -> NSImage? {
        if spec.lowercased().hasPrefix("sf=") { return symbolImage(spec) }

        let coreTypes = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/"
        switch spec.lowercased() {
        // AlertCautionIcon.icns is gone from recent macOS; the named image is the same icon.
        case "caution", "warning": return NSImage(contentsOfFile: coreTypes + "AlertCautionIcon.icns")
                                       ?? NSImage(named: NSImage.cautionName)
        case "info":               return NSImage(contentsOfFile: coreTypes + "AlertNoteIcon.icns")
        case "stop", "error":      return NSImage(contentsOfFile: coreTypes + "AlertStopIcon.icns")
        case "computer":           return NSImage(named: NSImage.computerName)
        default: break
        }

        let path = (spec as NSString).expandingTildeInPath
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        if path.hasSuffix(".app") || path.hasSuffix(".app/") {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return NSImage(contentsOfFile: path)
    }

    /// Parses "SF=name,key=value,…". A bare value after `palette=` adds another palette colour.
    private static func symbolImage(_ spec: String) -> NSImage? {
        var parts = spec.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return nil }
        let name = String(parts.removeFirst().dropFirst(3))

        var weight: NSFont.Weight = .regular
        var palette: [NSColor] = []
        var single: NSColor?
        var lastKey = ""
        for part in parts {
            let pair = part.split(separator: "=", maxSplits: 1).map(String.init)
            if pair.count == 2 {
                lastKey = pair[0].lowercased()
                switch lastKey {
                case "weight":                       weight = fontWeight(pair[1])
                case "palette":                      palette.append(color(pair[1]))
                case "colour", "color", "colour1", "color1": single = color(pair[1])
                case "colour2", "color2":            palette = [single ?? .labelColor, color(pair[1])]
                default: break
                }
            } else if lastKey == "palette" {
                palette.append(color(part))
            }
        }

        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        var config = NSImage.SymbolConfiguration(pointSize: 256, weight: weight)
        if palette.count >= 2 {
            config = config.applying(NSImage.SymbolConfiguration(paletteColors: palette))
        } else if let colour = single ?? palette.first {
            config = config.applying(NSImage.SymbolConfiguration(hierarchicalColor: colour))
        }
        return base.withSymbolConfiguration(config)
    }

    private static func fontWeight(_ value: String) -> NSFont.Weight {
        switch value.lowercased() {
        case "ultralight": return .ultraLight
        case "thin":       return .thin
        case "light":      return .light
        case "medium":     return .medium
        case "semibold":   return .semibold
        case "bold":       return .bold
        case "heavy":      return .heavy
        case "black":      return .black
        default:           return .regular
        }
    }

    /// Colour names and hex values, matching the brand colour preferences.
    static func color(_ value: String) -> NSColor {
        NSColor(hex: brandColorHex(value)) ?? .labelColor
    }
}

extension NSColor {
    /// "RRGGBB", with or without a leading "#".
    convenience init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt64(digits, radix: 16) else { return nil }
        self.init(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                  green:   CGFloat((value >> 8) & 0xFF) / 255,
                  blue:    CGFloat(value & 0xFF) / 255,
                  alpha:   1)
    }
}
