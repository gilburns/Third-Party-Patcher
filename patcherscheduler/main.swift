//
//  main.swift
//  patcherscheduler
//
//  Persistent LaunchDaemon. Manages patching cadence via an internal 600-second
//  timer and exposes a named Mach XPC service so PatcherMenu can trigger phases
//  on-demand without waiting for the next timer wake.
//

import Foundation

// MARK: - SIGTERM handling
//
// activeChildProcess holds the patcher subcommand Process currently being waited
// on.  The SIGTERM handler forwards the signal to it so patcher can finish its
// current installation before exiting, then exits the scheduler itself.
// Written only on the work queue; read on the GCD signal-handler thread.
var activeChildProcess: Process?

private func installSigtermHandler() {
    signal(SIGTERM, SIG_IGN)   // suppress default termination; we handle it below
    let src = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
    src.setEventHandler {
        Logger.log("⚠️ SIGTERM received — forwarding to active subcommand and exiting.")
        activeChildProcess?.terminate()
        Logger.log("⚠️ patcherscheduler exiting on SIGTERM.")
        exit(0)
    }
    src.resume()
    // Top-level binding keeps src alive for the process lifetime.
    _ = src
}


// MARK: - Entry point

// Handle read-only subcommands before acquiring the instance lock.
let cliArgs = Array(CommandLine.arguments.dropFirst())
if cliArgs.first == "status" {
    StatusReporter().run(args: cliArgs)
    exit(0)
}

// Acquire a single-instance lock as a safety net during package-upgrade races.
// KeepAlive in the LaunchDaemon plist guarantees at most one persistent instance,
// but the lock prevents a brief overlap if launchd restarts before the old
// instance has fully exited.
guard acquireSingleInstanceLock() else {
    fputs("patcherscheduler: another instance is already running — exiting.\n", stderr)
    exit(0)
}

installSigtermHandler()

Logger.log("patcherscheduler \(AppConstants.patcherVersion) started (pid \(AppConstants.currentPid))")


// MARK: - Serial work queue
//
// All phase runs (scheduled or on-demand) execute on this queue so they never
// overlap.  XPC-triggered work queues behind any in-progress cycle automatically.

let workQueue = DispatchQueue(label: "com.gilburns.patcher.work", qos: .utility)


// MARK: - XPC listener

let xpcDelegate = PatcherXPCDelegate(workQueue: workQueue)
let xpcListener = NSXPCListener(machServiceName: AppConstants.patcherXPCServiceName)
xpcListener.delegate = xpcDelegate
xpcListener.resume()
Logger.log("ℹ️ XPC listener active on '\(AppConstants.patcherXPCServiceName)'.")


// MARK: - Scheduled cycle timer

let cycleInterval: TimeInterval = 600

let cycleTimer: DispatchSourceTimer = {
    let t = DispatchSource.makeTimerSource(queue: .global())
    t.schedule(deadline: .now() + cycleInterval, repeating: cycleInterval)
    t.setEventHandler {
        workQueue.async {
            PatcherScheduler(prefs: Preferences()).runCycle()
        }
    }
    t.resume()
    return t
}()
// Top-level binding keeps the timer alive for the process lifetime.
_ = cycleTimer


// MARK: - Initial cycle

workQueue.async {
    PatcherScheduler(prefs: Preferences()).runCycle()
}


// MARK: - Run forever

RunLoop.main.run()


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
