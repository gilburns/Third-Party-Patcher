//
//  main.swift
//  patcherscheduler
//
//  Created by Gil Burns on 4/10/26.
//
//  Called by a LaunchDaemon on a fixed interval (e.g. every 10 minutes).
//  Each wake independently checks whether scan / check / stage / apply is due,
//  based on per-subcommand interval preferences and last-run timestamps.
//

import Foundation

// MARK: - SIGTERM handling
//
// activeChildProcess holds the patcher subcommand Process currently being waited
// on.  The SIGTERM handler forwards the signal to it so patcher can finish its
// current installation before exiting, then exits the scheduler itself.
// Written only on the main thread; read on the GCD signal-handler thread.
var activeChildProcess: Process?

private func installSigtermHandler() {
    signal(SIGTERM, SIG_IGN)   // suppress default termination; we handle it below
    let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    src.setEventHandler {
        Logger.log("⚠️ SIGTERM received — forwarding to active subcommand and exiting.")
        activeChildProcess?.terminate()   // patcher's own handler lets current install finish
        Logger.log("⚠️ patcherscheduler exiting on SIGTERM.")
        exit(0)
    }
    src.resume()
    // src is captured by the closure via the global DispatchSource retain path;
    // assigning to _ suppresses the unused-variable warning without releasing it.
    _ = src
}


// MARK: - Entry point

// Handle read-only subcommands before acquiring the instance lock — they don't
// modify any state so there's no need to block on another running instance.
let cliArgs = Array(CommandLine.arguments.dropFirst())
if cliArgs.first == "status" {
    StatusReporter().run(args: cliArgs)
    exit(0)
}

// Acquire a single-instance lock — if another patcherscheduler is already
// running (e.g. a previous scan hasn't finished) we exit without doing any work.
guard acquireSingleInstanceLock() else {
    fputs("patcherscheduler: another instance is already running — exiting.\n", stderr)
    exit(0)
}

installSigtermHandler()

Logger.log("patcherscheduler \(AppConstants.patcherVersion) started (pid \(AppConstants.currentPid))")

let prefs = Preferences()
let scheduler = PatcherScheduler(prefs: prefs)
scheduler.run()


// MARK: - Single-instance lock

/// Tries to acquire an exclusive non-blocking flock on a well-known lock file.
/// Returns true if the lock was acquired (this is the only running instance).
/// The fd is intentionally never stored or closed — the kernel releases the lock
/// automatically on exit, including crashes.
func acquireSingleInstanceLock() -> Bool {
    let lockPath = "/var/run/com.gilburns.patcherscheduler.lock"
    let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else {
        fputs("patcherscheduler: warning: could not open lock file \(lockPath)\n", stderr)
        return true   // proceed rather than being permanently locked out
    }
    if flock(fd, LOCK_EX | LOCK_NB) != 0 {
        return false  // EWOULDBLOCK — another instance is running
    }
    let pid = "\(ProcessInfo.processInfo.processIdentifier)\n"
    _ = pid.withCString { ptr in write(fd, ptr, strlen(ptr)) }
    // fd intentionally left open — lock persists until process exits.
    return true
}
