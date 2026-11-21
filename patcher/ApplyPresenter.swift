//
//  ApplyPresenter.swift
//  patcher
//
//  The user-facing side of patcher. Callers drive these protocols without knowing
//  how the UI is drawn: a window (NativeApplyWindow, or SwiftDialogController) or macOS notifications
//  (NotificationApplyPresenter). `Presenters` is the one place that picks the
//  window implementation.
//

import Foundation

/// The apply phase: progress for each item, blocking-process handling, completion.
protocol ApplyPresenter {
    /// Called once with every item about to be applied, before the first install.
    mutating func launchProgressDialog(items: [ApplyItem])
    func setProgressText(_ text: String)
    func setInProgress(item: ApplyItem, current: Int, total: Int)
    func setSuccess(item: ApplyItem, toVersion: String)
    func setFailed(item: ApplyItem)
    func setSkipped(item: ApplyItem, reason: String)
    /// Resolves a running blocking process for `item`; may block while waiting for the user.
    /// When `deferIfScreenLocks` is true, a prompt that is still waiting when the screen
    /// locks is withdrawn and the item skipped, rather than timing out and force-quitting
    /// an app nobody is there to save. (False once the hard deadline is reached.)
    func handleBlockingProcess(processName: String, item: ApplyItem,
                               action: BlockingProcessAction, countdownSeconds: Int,
                               deferIfScreenLocks: Bool) -> BlockingActionResponse
    func complete(applied: Int, skipped: Int, failed: Int)
    func waitForDialog(timeout: TimeInterval?)
    func dismiss()
}

/// The pre-install prompt that lets the user continue now or defer.
protocol DeferralPresenter {
    /// Blocks until the user answers, the countdown expires, or the prompt fails.
    /// Returns `.deadlineForced` when `hardDeadlineReached` is true, whatever the user did.
    func showDeferralPrompt(
        items:                  [ApplyItem],
        daysPending:            Int,
        hardDeadlineReached:    Bool,
        allowedDeferralMinutes: [Int],
        prefs:                  Preferences
    ) -> DeferralPromptResult
}

/// A window-based presenter handles both the deferral prompt and the apply phase.
typealias ApplyWindowPresenter = ApplyPresenter & DeferralPresenter

/// The small "please wait" window for user-initiated scan / check / stage runs.
protocol ProgressWindowPresenter {
    func update(message: String)
    func updateProgress(_ text: String)
    func setProgress(_ current: Int, of total: Int, label: String, icon: String?)
    /// Starts a long item (e.g. a download): shows its label and icon, and switches the
    /// bar to indeterminate.
    func beginItem(current: Int, of total: Int, label: String, icon: String?)
    /// Ends a long item: restores the determinate bar advanced to `current`.
    func completeItem(current: Int, of total: Int)
    /// Restores the icons shown when the window first opened.
    func resetIcons()
    func close()
}

extension SwiftDialogController: ApplyPresenter, DeferralPresenter {}

enum Presenters {

    /// The window presenter for the apply phase, or nil when no window can be shown
    /// (UI disabled, no console user, or the UI is unavailable). nil means apply silently.
    ///
    /// Native windows are used when PatcherNotifier is loaded for the console user.
    /// Until the native prompts exist, swiftDialog still draws the deferral and
    /// blocking-app prompts, and is the whole UI when PatcherNotifier isn't loaded.
    static func makeApplyWindow() -> (any ApplyWindowPresenter)? {
        guard Preferences().swiftDialogEnabled else { return nil }
        if let uid = PatcherNotifierAgent.windowTargetUID() {
            return NativeApplyWindow(uid: uid, prompts: SwiftDialogController.makeIfAvailable())
        }
        return SwiftDialogController.makeIfAvailable()
    }

    /// Opens a progress window for a user-initiated run, or returns nil when none can be shown.
    static func makeProgressWindow(title: String, message: String, total: Int = 0) -> (any ProgressWindowPresenter)? {
        if let uid = PatcherNotifierAgent.windowTargetUID() {
            return NativeProgressWindow(uid: uid, title: title, message: message, total: total)
        }
        return SwiftDialogController.launchProgressWindow(title: title, message: message, total: total)
    }
}
