//
//  ApplyPresenter.swift
//  patcher
//
//  The user-facing side of the apply phase. applyUpdates drives one of these
//  without knowing whether it is a swiftDialog window (SwiftDialogController)
//  or macOS notifications (NotificationApplyPresenter).
//

import Foundation

protocol ApplyPresenter {
    typealias ApplyItem = SwiftDialogController.ApplyItem

    /// Called once with every item about to be applied, before the first install.
    mutating func launchProgressDialog(items: [ApplyItem])
    func setProgressText(_ text: String)
    func setInProgress(item: ApplyItem, current: Int, total: Int)
    func setSuccess(item: ApplyItem, toVersion: String)
    func setFailed(item: ApplyItem)
    func setSkipped(item: ApplyItem, reason: String)
    /// Resolves a running blocking process for `item`; may block while waiting for the user.
    func handleBlockingProcess(processName: String, item: ApplyItem,
                               action: BlockingProcessAction, countdownSeconds: Int) -> BlockingActionResponse
    func complete(applied: Int, skipped: Int, failed: Int)
    func waitForDialog(timeout: TimeInterval?)
    func dismiss()
}

extension SwiftDialogController: ApplyPresenter {}
