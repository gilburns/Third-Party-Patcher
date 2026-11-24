//
//  LiveProgress.swift
//  patcher
//
//  Progress of the download or install running now, for the window showing it.
//
//  The stage and apply loops install a handler around one item (`push` / `pop`); the
//  download and install functions deep below report into it without knowing which
//  window, if any, is listening. With no handler installed, reports are dropped, so
//  scheduled runs without a window cost nothing. Handlers nest: `patcher ensure` listens
//  for the whole run, and an apply window inside it takes over until it pops.
//
//  Reports are throttled: every one rewrites the window's session file, so within a step
//  one goes out only when the fraction has moved at least 1% and half a second has passed.
//

import Foundation

enum LiveProgress {

    /// The step now running and how far along it is; `detail.fraction` is nil when the
    /// step can't measure itself (a spinner is shown).
    typealias Handler = (_ detail: ProgressDetail) -> Void

    private static let lock = NSLock()
    private static var handler: Handler?
    private static var lastSent = Date.distantPast
    private static var last: ProgressDetail?

    private static let minInterval: TimeInterval = 0.5
    private static let minStep = 0.01

    /// Sends reports to `handler` until `pop`. Returns the handler it replaced, for `pop`.
    @discardableResult
    static func push(_ handler: @escaping Handler) -> Handler? {
        lock.lock(); defer { lock.unlock() }
        let previous = self.handler
        self.handler = handler
        resetThrottle()
        return previous
    }

    /// Restores the handler `push` replaced (nil for none). Once this returns, the popped
    /// handler is never called again.
    static func pop(restoring previous: Handler?) {
        lock.lock(); defer { lock.unlock() }
        handler = previous
        resetThrottle()
    }

    private static func resetThrottle() {
        lastSent = .distantPast
        last     = nil
    }

    /// Reports progress; safe from any thread. Throttled, and dropped when nobody listens.
    static func report(_ detail: ProgressDetail) {
        lock.lock(); defer { lock.unlock() }
        guard let handler else { return }
        let fraction     = detail.fraction
        let lastFraction = last?.fraction
        let now = Date()

        // A new step (downloading → installing, or measured ↔ unmeasured) goes out at
        // once; within a step, only when it has moved and half a second has passed.
        let newStep    = detail.step != last?.step || (fraction == nil) != (lastFraction == nil)
        let reachedEnd = fraction == 1 && lastFraction != 1
        let moved: Bool
        if let fraction, let lastFraction {
            moved = abs(fraction - lastFraction) >= minStep
        } else {
            moved = detail != last
        }
        let due = now.timeIntervalSince(lastSent) >= minInterval
        guard newStep || reachedEnd || (moved && due) else { return }

        lastSent = now
        last     = detail
        handler(detail)
    }
}

/// The output of a process run with `runStreaming`.
struct StreamedOutput {
    var stdout: String
    var stderr: String
}

/// Runs `process` to completion, handing each line of its output to `onStdout` /
/// `onStderr` as it arrives. Lines end at "\n" or "\r" (curl redraws its progress bar
/// with "\r"). Returns all of each stream's text.
///
/// The output is read while the process runs, so a chatty process can't fill the pipe
/// and stall, and every line has been handled by the time this returns.
func runStreaming(_ process: Process,
                  onStdout: ((String) -> Void)? = nil,
                  onStderr: ((String) -> Void)? = nil) throws -> StreamedOutput {
    let outPipe = Pipe()
    let errPipe = Pipe()
    process.standardOutput = outPipe
    process.standardError  = errPipe
    try process.run()

    let group  = DispatchGroup()
    let out    = StreamReader(pipe: outPipe, onLine: onStdout)
    let err    = StreamReader(pipe: errPipe, onLine: onStderr)
    for reader in [out, err] {
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            reader.readToEnd()
            group.leave()
        }
    }
    process.waitUntilExit()
    group.wait()
    return StreamedOutput(stdout: out.text, stderr: err.text)
}

/// Reads one pipe to end of file on a background thread, splitting it into lines.
private final class StreamReader: @unchecked Sendable {
    private let handle: FileHandle
    private let onLine: ((String) -> Void)?
    /// Written only by `readToEnd`; read after it has finished.
    private var data = Data()

    init(pipe: Pipe, onLine: ((String) -> Void)?) {
        self.handle = pipe.fileHandleForReading
        self.onLine = onLine
    }

    var text: String { String(decoding: data, as: UTF8.self) }

    func readToEnd() {
        var pending = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }      // end of file: the process closed the pipe
            data.append(chunk)
            guard let onLine else { continue }
            pending.append(chunk)
            while let end = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = String(decoding: pending[pending.startIndex..<end], as: UTF8.self)
                pending.removeSubrange(pending.startIndex...end)
                if !line.isEmpty { onLine(line) }
            }
        }
        if let onLine, !pending.isEmpty { onLine(String(decoding: pending, as: UTF8.self)) }
    }
}

// MARK: - Output parsing

/// The percentage in a line of curl's `--progress-bar` output ("#####   45.2%"), as 0…1.
func curlProgressFraction(_ line: String) -> Double? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasSuffix("%"),
          let number = trimmed.dropLast().split(separator: " ").last,
          let value = Double(number) else { return nil }
    return value / 100
}

enum InstallerLine: Equatable {
    case percent(Double)
    case phase(String)
    case message(String)
}

/// One line of `installer -verboseR` output.
func parseInstallerLine(_ line: String) -> InstallerLine {
    let prefix = "installer:"
    guard line.hasPrefix(prefix) else { return .message(line) }
    let rest = line.dropFirst(prefix.count)
    if rest.hasPrefix("%"), let value = Double(rest.dropFirst()) {
        return .percent(value / 100)
    }
    for tag in ["PHASE:", "STATUS:"] where rest.hasPrefix(tag) {
        return .phase(String(rest.dropFirst(tag.count)))
    }
    return .message(line)
}

/// The path in a line of `ditto -V` output ("copying file ./Contents/Info.plist ... "),
/// relative to the source, with its "./" prefix.
func dittoCopiedPath(_ line: String) -> String? {
    let prefix = "copying file "
    guard line.hasPrefix(prefix) else { return nil }
    var path = line.dropFirst(prefix.count)
    while path.last == " " { path = path.dropLast() }
    guard path.hasSuffix(" ...") else { return nil }
    return String(path.dropLast(4))
}

/// The size of every regular file under `root`, keyed the way `ditto -V` names them
/// ("./Contents/Info.plist"). Symbolic links are not followed.
func fileSizes(in root: String) -> [String: Int64] {
    var sizes: [String: Int64] = [:]
    guard let walker = FileManager.default.enumerator(atPath: root) else { return sizes }
    while let relative = walker.nextObject() as? String {
        guard let attributes = walker.fileAttributes,
              attributes[.type] as? FileAttributeType == .typeRegular else { continue }
        sizes["./" + relative] = (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
    return sizes
}

// MARK: - Shared state for output readers

/// Lines collected from a reader thread.
final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock(); defer { lock.unlock() }
        lines.append(line)
    }

    var joined: String {
        lock.lock(); defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}

/// How much of an app `ditto -V` has copied, by size. ditto names each file as it
/// starts, so a file counts as copied once the next one starts.
final class DittoCopyProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let sizes: [String: Int64]
    private let total: Int64
    private var copied: Int64 = 0
    private var current: String?

    init(source: String) {
        sizes = fileSizes(in: source)
        total = max(sizes.values.reduce(0, +), 1)
    }

    /// Records that ditto started `path`; returns the share copied before it, 0…1.
    func starting(_ path: String) -> Double {
        lock.lock(); defer { lock.unlock() }
        if let current { copied += sizes[current] ?? 0 }
        current = path
        return Double(copied) / Double(total)
    }
}
