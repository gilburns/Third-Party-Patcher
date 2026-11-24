//
//  DialogText.swift
//
//  Text patcher sends to PatcherNotifier as typed values instead of finished English.
//  patcher (root, no app bundle) can't know the console user's language, so a session
//  carries what to say (a message and its values) and PatcherNotifier words it in the
//  user's language. Code also compares these values, never displayed text.
//
//  Translations live in PatcherNotifier's "Dialogs" table. Apps that show the same text
//  (Available Software's live status) read it from PatcherNotifier.app; patcher reads its
//  own bundle, which has no table, so its copy — logs and the legacy English session
//  fields — stays English.
//
//  Sessions carry both: the typed value (`@Lenient`, so a value from a newer patcher that
//  this build can't decode is dropped rather than failing the whole file) and the English
//  string older PatcherNotifier builds draw.
//

import Foundation

/// A message for the user. Cases carry values, not words; `text` words them.
indirect enum DialogText: Codable, Equatable {
    /// Shown as-is: app names, admin-supplied text, and text not yet converted.
    case verbatim(String)
    /// Progress of the step now running.
    case progress(ProgressDetail)
    /// Why an item was skipped (or paused).
    case skipped(SkipReason)
    /// Whole sentences or paragraphs, separated by blank lines.
    case paragraphs([DialogText])

    /// The message in the reader's language.
    var text: String {
        switch self {
        case .verbatim(let string):     return string
        case .progress(let detail):     return detail.text
        case .skipped(let reason):      return reason.text
        case .paragraphs(let parts):    return parts.map(\.text).joined(separator: "\n\n")
        }
    }
}

/// Why an item in the apply window was skipped.
enum SkipReason: String, Codable, Equatable {
    case noPlist
    case noType
    case unavailableDrive
    case appRemoved
    case noInstallTarget
    case screenLocked
    case appRunning
    /// Not a result: the item waits while the blocking prompt asks the user.
    case waitingForUser

    var text: String {
        let b = Bundle.dialogStrings
        switch self {
        case .noPlist:
            return String(localized: "No plist", table: "Dialogs", bundle: b,
                          comment: "Apply window row: skipped, the app's update details are missing")
        case .noType:
            return String(localized: "No type", table: "Dialogs", bundle: b,
                          comment: "Apply window row: skipped, the update's install type is unknown")
        case .unavailableDrive:
            return String(localized: "Unavailable Drive", table: "Dialogs", bundle: b,
                          comment: "Apply window row: skipped, the app is on a drive that isn't available")
        case .appRemoved:
            return String(localized: "App removed", table: "Dialogs", bundle: b,
                          comment: "Apply window row: skipped, the app was deleted since the scan")
        case .noInstallTarget:
            return String(localized: "No install target", table: "Dialogs", bundle: b,
                          comment: "Apply window row: skipped, nowhere to install the app")
        case .screenLocked:
            return String(localized: "Screen locked", table: "Dialogs", bundle: b,
                          comment: "Apply window row: skipped, the screen locked while waiting to quit the app")
        case .appRunning:
            return String(localized: "App running", table: "Dialogs", bundle: b,
                          comment: "Apply window row: skipped, the app is open and can't be updated")
        case .waitingForUser:
            return String(localized: "Waiting for user…", table: "Dialogs", bundle: b,
                          comment: "Apply window row: paused while a prompt asks the user to quit the app")
        }
    }
}

/// Progress of the download or install step now running.
enum ProgressDetail: Codable, Equatable {
    /// Which kind of step, for telling a new step from progress within one.
    enum Step: String, Codable, Equatable {
        case downloading, installing, copying, openingDiskImage, extracting
    }

    /// `received` / `total` in bytes, when known. curl reports only a fraction.
    case downloading(fraction: Double?, received: Int64?, total: Int64?)
    case installing(fraction: Double?)
    case copying(fraction: Double?)
    case openingDiskImage
    case extracting

    var step: Step {
        switch self {
        case .downloading:      return .downloading
        case .installing:       return .installing
        case .copying:          return .copying
        case .openingDiskImage: return .openingDiskImage
        case .extracting:       return .extracting
        }
    }

    /// 0…1, or nil when the step can't measure itself (a spinner is shown).
    var fraction: Double? {
        let raw: Double?
        switch self {
        case .downloading(let fraction, _, _), .installing(let fraction), .copying(let fraction):
            raw = fraction
        case .openingDiskImage, .extracting:
            raw = nil
        }
        return raw.map { min(max($0, 0), 1) }
    }

    /// "Downloading 45% · 12 MB of 98 MB", "Installing 30%", "Extracting…".
    var text: String {
        let b = Bundle.dialogStrings
        switch self {
        case .downloading(_, let received, let total):
            if let percent = percentText {
                if let received, let total, total > 0 {
                    let receivedText = Self.bytes(received), totalText = Self.bytes(total)
                    return String(localized: "Downloading \(percent) · \(receivedText) of \(totalText)",
                                  table: "Dialogs", bundle: b,
                                  comment: "Download progress: percent, then bytes received of the total size")
                }
                return String(localized: "Downloading \(percent)", table: "Dialogs", bundle: b,
                              comment: "Download progress: percent done")
            }
            if let received, received > 0 {
                let receivedText = Self.bytes(received)
                return String(localized: "Downloading · \(receivedText)", table: "Dialogs", bundle: b,
                              comment: "Download progress when the total size is unknown: bytes received so far")
            }
            return String(localized: "Downloading…", table: "Dialogs", bundle: b,
                          comment: "Download progress before anything has been received")
        case .installing:
            if let percent = percentText {
                return String(localized: "Installing \(percent)", table: "Dialogs", bundle: b,
                              comment: "Install progress: percent done")
            }
            return String(localized: "Installing…", table: "Dialogs", bundle: b,
                          comment: "Install progress that can't be measured")
        case .copying:
            if let percent = percentText {
                return String(localized: "Copying \(percent)", table: "Dialogs", bundle: b,
                              comment: "Progress copying an app into place: percent done")
            }
            return String(localized: "Copying…", table: "Dialogs", bundle: b,
                          comment: "Progress copying an app into place, not measured")
        case .openingDiskImage:
            return String(localized: "Opening disk image…", table: "Dialogs", bundle: b,
                          comment: "Install step: mounting the downloaded disk image")
        case .extracting:
            return String(localized: "Extracting…", table: "Dialogs", bundle: b,
                          comment: "Install step: unpacking the downloaded archive")
        }
    }

    /// "45%", rounded down so 100% means done.
    private var percentText: String? {
        fraction.map { (($0 * 100).rounded(.down) / 100).formatted(.percent.precision(.fractionLength(0))) }
    }

    private static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }
}

// MARK: - Bundle

extension Bundle {
    /// Where the "Dialogs" table lives: PatcherNotifier itself, or PatcherNotifier.app for
    /// the other apps. Command-line tools (patcher) use their own bundle, which has no
    /// table, so they get the English the strings are written in.
    static let dialogStrings: Bundle = {
        let main = Bundle.main
        guard main.bundleURL.pathExtension == "app" else { return main }
        if main.bundleURL.lastPathComponent == AppConstants.patcherNotifierAppURL.lastPathComponent { return main }
        return Bundle(url: AppConstants.patcherNotifierAppURL) ?? main
    }()
}

// MARK: - Lenient decoding

/// An optional field whose value is dropped, rather than failing the whole decode, when
/// it can't be read: a typed value from a newer patcher that this build doesn't know.
/// The legacy English field beside it still shows.
@propertyWrapper
struct Lenient<Value: Codable & Equatable>: Codable, Equatable {
    var wrappedValue: Value?

    init(wrappedValue: Value?) { self.wrappedValue = wrappedValue }

    init(from decoder: Decoder) throws {
        wrappedValue = try? Value(from: decoder)
    }

    func encode(to encoder: Encoder) throws {
        try wrappedValue.encode(to: encoder)
    }
}

extension KeyedDecodingContainer {
    /// A missing key, or one that won't decode, is nil.
    func decode<Value>(_ type: Lenient<Value>.Type, forKey key: Key) throws -> Lenient<Value> {
        (try? decodeIfPresent(type, forKey: key)) ?? Lenient(wrappedValue: nil)
    }
}

extension KeyedEncodingContainer {
    /// nil is left out of the file, as for plain optionals.
    mutating func encode<Value>(_ value: Lenient<Value>, forKey key: Key) throws {
        if let wrapped = value.wrappedValue { try encode(wrapped, forKey: key) }
    }
}
