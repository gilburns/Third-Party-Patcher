//
//  patcherTests.swift
//  patcherTests
//
//  Tests for pure patcher logic — no process launching, no disk I/O,
//  no window UI interaction.
//

import Testing
import Foundation

// MARK: - parseScriptOutput

struct ParseScriptOutputTests {

    @Test func parsesValidJSON() {
        let json = """
        {"label":"googlechrome","name":"Google Chrome","downloadURL":"https://example.com/chrome.dmg","expectedTeamID":"EQHXZ8M8AV"}
        """
        let result = parseScriptOutput(json)
        #expect(result != nil)
        #expect(result?["label"] as? String == "googlechrome")
        #expect(result?["name"] as? String == "Google Chrome")
    }

    @Test func returnsNilForEmptyString() {
        #expect(parseScriptOutput("") == nil)
    }

    @Test func returnsNilForPlainText() {
        #expect(parseScriptOutput("not json") == nil)
    }

    @Test func returnsNilForJSONArray() {
        // Top-level array is not a [String: Any]
        #expect(parseScriptOutput("[1,2,3]") == nil)
    }

    @Test func parsesNestedArrayValue() {
        let json = """
        {"blockingProcesses":["Safari","Chrome"],"label":"test"}
        """
        let result = parseScriptOutput(json)
        let procs = result?["blockingProcesses"] as? [String]
        #expect(procs == ["Safari", "Chrome"])
    }

    @Test func parsesEmptyObject() {
        let result = parseScriptOutput("{}")
        #expect(result != nil)
        #expect(result?.isEmpty == true)
    }
}


// MARK: - validateLabelRequiredKeys

struct ValidateLabelRequiredKeysTests {

    // Minimal valid dict — all four required keys present and non-empty
    private func validDict() -> [String: Any] {
        [
            "name":           "Google Chrome",
            "type":           "dmg",
            "downloadURL":    "https://example.com/chrome.dmg",
            "expectedTeamID": "EQHXZ8M8AV",
        ]
    }

    @Test func passesWithAllRequiredKeys() {
        #expect(validateLabelRequiredKeys(validDict(), label: "googlechrome"))
    }

    @Test func failsWhenNameMissing() {
        var d = validDict(); d.removeValue(forKey: "name")
        #expect(!validateLabelRequiredKeys(d, label: "googlechrome"))
    }

    @Test func failsWhenTypeMissing() {
        var d = validDict(); d.removeValue(forKey: "type")
        #expect(!validateLabelRequiredKeys(d, label: "googlechrome"))
    }

    @Test func failsWhenDownloadURLMissing() {
        var d = validDict(); d.removeValue(forKey: "downloadURL")
        #expect(!validateLabelRequiredKeys(d, label: "googlechrome"))
    }

    @Test func failsWhenExpectedTeamIDMissing() {
        var d = validDict(); d.removeValue(forKey: "expectedTeamID")
        #expect(!validateLabelRequiredKeys(d, label: "googlechrome"))
    }

    @Test func failsWhenNameIsEmpty() {
        var d = validDict(); d["name"] = ""
        #expect(!validateLabelRequiredKeys(d, label: "googlechrome"))
    }

    @Test func failsWhenDownloadURLIsEmpty() {
        var d = validDict(); d["downloadURL"] = ""
        #expect(!validateLabelRequiredKeys(d, label: "googlechrome"))
    }

    @Test func failsWithEmptyDict() {
        #expect(!validateLabelRequiredKeys([:], label: "empty"))
    }

    @Test func failsWhenValueIsWrongType() {
        var d = validDict(); d["name"] = 42   // Int instead of String
        #expect(!validateLabelRequiredKeys(d, label: "wrongtype"))
    }
}


// MARK: - UpdateStatus

struct UpdateStatusTests {

    @Test func rawValuesRoundTrip() {
        #expect(UpdateStatus(rawValue: "updateRequired") == .updateRequired)
        #expect(UpdateStatus(rawValue: "delayed")        == .delayed)
        #expect(UpdateStatus(rawValue: "upToDate")       == .upToDate)
        #expect(UpdateStatus(rawValue: "wouldDowngrade") == .wouldDowngrade)
        #expect(UpdateStatus(rawValue: "unknown")        == .unknown)
    }

    @Test func invalidRawValueReturnsNil() {
        #expect(UpdateStatus(rawValue: "bogus") == nil)
    }
}


// MARK: - UpdateDelay

struct UpdateDelayTests {

    private let day: TimeInterval = 86_400
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func history(_ found: [(installed: String, available: String, daysAgo: Double)]) -> LabelHistory {
        let events = found.map {
            LabelHistoryEvent.updateFound(date: now.addingTimeInterval(-$0.daysAgo * day),
                                          installedVersion: $0.installed,
                                          availableVersion: $0.available)
        }
        return LabelHistory(firstDiscoveredDate: now.addingTimeInterval(-100 * day),
                            firstDiscoveredVersion: "1.0", events: events)
    }

    private func hold(_ prefs: [String: Any], label: String = "zoom", installed: String = "1.0",
                      available: String, history h: LabelHistory?) -> UpdateDelay.Hold? {
        UpdateDelay.hold(label: label, installedVersion: installed, availableVersion: available,
                         history: h, prefs: Preferences(testPrefs: prefs), now: now)
    }

    @Test func noDelayByDefault() {
        #expect(hold([:], available: "2.0", history: history([("1.0", "2.0", 0)])) == nil)
    }

    @Test func holdsNewVersionUntilDelayElapses() {
        let h = hold(["UpdateDelayDays": 3], available: "2.0", history: history([("1.0", "2.0", 1)]))
        #expect(h != nil)
        #expect(h?.delayDays == 3)
        #expect(h?.eligibleDate == now.addingTimeInterval(2 * day))
    }

    @Test func releasesOnceDelayElapsed() {
        #expect(hold(["UpdateDelayDays": 3], available: "2.0", history: history([("1.0", "2.0", 3)])) == nil)
    }

    @Test func graceReleasesSlightlyEarlyCheck() {
        // Seen 23h ago with a 1-day delay — within the grace window, so released.
        #expect(hold(["UpdateDelayDays": 1], available: "2.0", history: history([("1.0", "2.0", 23.0 / 24)])) == nil)
    }

    @Test func supersedingReleaseRestartsClock() {
        let h = hold(["UpdateDelayDays": 3], available: "2.1",
                     history: history([("1.0", "2.0", 5), ("1.0", "2.1", 1)]))
        #expect(h?.versionFirstSeen == now.addingTimeInterval(-1 * day))
    }

    @Test func revertedReleaseKeepsOriginalClock() {
        // 2.0 seen 5 days ago, 2.1 appeared then was pulled — 2.0 keeps its original sighting.
        let h = history([("1.0", "2.0", 5), ("1.0", "2.1", 2), ("1.0", "2.0", 1)])
        #expect(hold(["UpdateDelayDays": 3], available: "2.0", history: h) == nil)
    }

    @Test func ignoresSightingsFromAnOlderInstalledVersion() {
        // 2.0 was seen long ago while 0.9 was installed; the clock restarts for 1.0.
        let h = history([("0.9", "2.0", 30), ("1.0", "2.0", 1)])
        #expect(hold(["UpdateDelayDays": 3], available: "2.0", history: h) != nil)
    }

    @Test func maxWaitReleasesFrequentReleases() {
        let h = history([("1.0", "2.0", 8), ("1.0", "2.1", 6), ("1.0", "2.2", 3), ("1.0", "2.3", 0)])
        #expect(hold(["UpdateDelayDays": 3, "UpdateDelayMaxDays": 7], available: "2.3", history: h) == nil)
        #expect(hold(["UpdateDelayDays": 3], available: "2.3", history: h) != nil)
    }

    @Test func maxWaitCapsEligibleDate() {
        let h = history([("1.0", "2.0", 5), ("1.0", "2.1", 0)])
        let held = hold(["UpdateDelayDays": 3, "UpdateDelayMaxDays": 6], available: "2.1", history: h)
        #expect(held?.eligibleDate == now.addingTimeInterval(1 * day))
    }

    @Test func missingHistoryDoesNotHold() {
        #expect(hold(["UpdateDelayDays": 3], available: "2.0", history: nil) == nil)
    }

    @Test func overrideExactBeatsWildcard() {
        let prefs = Preferences(testPrefs: ["UpdateDelayDays": 2,
                                            "UpdateDelayOverrides": "zoom*:7 zoom:0 google*:5"])
        #expect(UpdateDelay.delayDays(for: "zoom", prefs: prefs) == 0)
        #expect(UpdateDelay.delayDays(for: "zoomclient", prefs: prefs) == 7)
        #expect(UpdateDelay.delayDays(for: "GoogleChrome", prefs: prefs) == 5)
        #expect(UpdateDelay.delayDays(for: "firefox", prefs: prefs) == 2)
    }

    @Test func overrideCanDelayWhenGlobalIsOff() {
        let prefs: [String: Any] = ["UpdateDelayOverrides": "zoom:3"]
        #expect(hold(prefs, available: "2.0", history: history([("1.0", "2.0", 0)])) != nil)
        #expect(hold(prefs, label: "firefox", available: "2.0", history: history([("1.0", "2.0", 0)])) == nil)
    }

    @Test func malformedOverridesIgnored() {
        let prefs = Preferences(testPrefs: ["UpdateDelayOverrides": "zoom firefox:x :3 chrome:-1 slack:4 a:1:2"])
        #expect(prefs.updateDelayOverrides.map(\.pattern) == ["slack"])
    }
}


// MARK: - DeferralState (patcher perspective)

struct PatcherDeferralStateTests {

    @Test func freshStateIsInactive() {
        #expect(!DeferralState().isActive())
    }

    @Test func activeAfterRecording() {
        var state = DeferralState()
        let now = Date()
        state.recordDeferral(minutes: 30, now: now)
        #expect(state.isActive(now: now.addingTimeInterval(15 * 60)))
    }

    @Test func inactiveAfterReset() {
        var state = DeferralState()
        state.recordDeferral(minutes: 120)
        state.reset()
        #expect(!state.isActive())
        #expect(state.count == 0)
    }

    @Test func multipleDefferralsAccumulateCount() {
        var state = DeferralState()
        for _ in 1...5 { state.recordDeferral(minutes: 60) }
        #expect(state.count == 5)
    }
}


// MARK: - LabelHistory

struct LabelHistoryTests {

    // MARK: Event factories

    @Test func discoveredEventHasCorrectFields() {
        let date    = Date()
        let version = "1.0"
        let event   = LabelHistoryEvent.discovered(date: date, installedVersion: version)
        #expect(event.type == LabelHistoryEvent.EventType.discovered)
        #expect(event.installedVersion == version)
        #expect(event.availableVersion == nil)
        #expect(event.downloadURL == nil)
        #expect(event.fileSizeBytes == nil)
        #expect(event.fromVersion == nil)
        #expect(event.toVersion == nil)
    }

    @Test func updateFoundEventHasCorrectFields() {
        let event = LabelHistoryEvent.updateFound(date: Date(), installedVersion: "1.0", availableVersion: "2.0")
        #expect(event.type == LabelHistoryEvent.EventType.updateFound)
        #expect(event.installedVersion == "1.0")
        #expect(event.availableVersion == "2.0")
    }

    @Test func stagedEventHasCorrectFields() {
        let event = LabelHistoryEvent.staged(date: Date(), availableVersion: "2.0",
                                              downloadURL: "https://example.com/app.dmg",
                                              fileSizeBytes: 1_024_000)
        #expect(event.type == LabelHistoryEvent.EventType.staged)
        #expect(event.availableVersion == "2.0")
        #expect(event.downloadURL == "https://example.com/app.dmg")
        #expect(event.fileSizeBytes == 1_024_000)
    }

    @Test func appliedEventHasCorrectFields() {
        let event = LabelHistoryEvent.applied(date: Date(), fromVersion: "1.0", toVersion: "2.0")
        #expect(event.type == LabelHistoryEvent.EventType.applied)
        #expect(event.fromVersion == "1.0")
        #expect(event.toVersion == "2.0")
        #expect(event.installedVersion == nil)
    }

    // MARK: lastEvent(ofType:)

    @Test func lastEventReturnsNilForEmptyHistory() {
        let history = LabelHistory(firstDiscoveredDate: Date(), firstDiscoveredVersion: "1.0", events: [])
        #expect(history.lastEvent(ofType: LabelHistoryEvent.EventType.applied) == nil)
    }

    @Test func lastEventReturnsCorrectType() {
        let e1 = LabelHistoryEvent.discovered(date: Date(), installedVersion: "1.0")
        let e2 = LabelHistoryEvent.updateFound(date: Date(), installedVersion: "1.0", availableVersion: "2.0")
        let e3 = LabelHistoryEvent.applied(date: Date(), fromVersion: "1.0", toVersion: "2.0")
        let history = LabelHistory(firstDiscoveredDate: Date(), firstDiscoveredVersion: "1.0",
                                   events: [e1, e2, e3])
        let last = history.lastEvent(ofType: LabelHistoryEvent.EventType.applied)
        #expect(last?.toVersion == "2.0")
    }

    @Test func lastEventReturnsNilForMissingType() {
        let e1 = LabelHistoryEvent.discovered(date: Date(), installedVersion: "1.0")
        let history = LabelHistory(firstDiscoveredDate: Date(), firstDiscoveredVersion: "1.0", events: [e1])
        #expect(history.lastEvent(ofType: LabelHistoryEvent.EventType.applied) == nil)
    }

    @Test func lastEventReturnsLastOfMultiple() {
        let e1 = LabelHistoryEvent.updateFound(date: Date(), installedVersion: "1.0", availableVersion: "2.0")
        let e2 = LabelHistoryEvent.updateFound(date: Date(), installedVersion: "2.0", availableVersion: "3.0")
        let history = LabelHistory(firstDiscoveredDate: Date(), firstDiscoveredVersion: "1.0", events: [e1, e2])
        #expect(history.lastEvent(ofType: LabelHistoryEvent.EventType.updateFound)?.availableVersion == "3.0")
    }

    // MARK: EventType constants

    @Test func eventTypeConstantsAreDistinct() {
        let types = [
            LabelHistoryEvent.EventType.discovered,
            LabelHistoryEvent.EventType.updateFound,
            LabelHistoryEvent.EventType.staged,
            LabelHistoryEvent.EventType.applied,
        ]
        #expect(Set(types).count == 4)
    }
}


// MARK: - Codable round-trips (in-memory, no filesystem)

struct CodableRoundTripTests {

    private var encoder: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }
    private var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }

    // MARK: DeferralState

    @Test func deferralStateRoundTripWithActiveDeferral() throws {
        var state = DeferralState()
        let now = Date()
        state.recordDeferral(minutes: 90, now: now)
        state.recordDeferral(minutes: 60, now: now)   // count = 2, expiry = now + 60 min

        let decoded = try decoder.decode(DeferralState.self, from: try encoder.encode(state))

        #expect(decoded.count == 2)
        #expect(decoded.expiryDate != nil)
        #expect(abs(decoded.expiryDate!.timeIntervalSince(state.expiryDate!)) < 1.0)
        #expect(decoded.isActive(now: now))
    }

    @Test func deferralStateRoundTripAfterReset() throws {
        var state = DeferralState()
        state.recordDeferral(minutes: 120)
        state.reset()

        let decoded = try decoder.decode(DeferralState.self, from: try encoder.encode(state))

        #expect(decoded.expiryDate == nil)
        #expect(decoded.count == 0)
        #expect(!decoded.isActive())
    }

    @Test func deferralStateRoundTripFreshState() throws {
        let state   = DeferralState()
        let decoded = try decoder.decode(DeferralState.self, from: try encoder.encode(state))

        #expect(decoded.expiryDate == nil)
        #expect(decoded.count == 0)
    }

    // MARK: LabelHistory

    @Test func labelHistoryRoundTripPreservesAllEventTypes() throws {
        let now = Date()
        let events: [LabelHistoryEvent] = [
            .discovered(date: now, installedVersion: "1.0"),
            .updateFound(date: now, installedVersion: "1.0", availableVersion: "2.0"),
            .staged(date: now, availableVersion: "2.0", downloadURL: "https://example.com/app.dmg", fileSizeBytes: 512_000),
            .applied(date: now, fromVersion: "1.0", toVersion: "2.0"),
        ]
        let history = LabelHistory(firstDiscoveredDate: now, firstDiscoveredVersion: "1.0", events: events)

        let decoded = try decoder.decode(LabelHistory.self, from: try encoder.encode(history))

        #expect(decoded.firstDiscoveredVersion == "1.0")
        #expect(decoded.events.count == 4)
        #expect(decoded.events[0].type == LabelHistoryEvent.EventType.discovered)
        #expect(decoded.events[1].availableVersion == "2.0")
        #expect(decoded.events[2].fileSizeBytes == 512_000)
        #expect(decoded.events[2].downloadURL == "https://example.com/app.dmg")
        #expect(decoded.events[3].fromVersion == "1.0")
        #expect(decoded.events[3].toVersion == "2.0")
    }

    @Test func labelHistoryRoundTripPreservesDates() throws {
        let now = Date()
        let history = LabelHistory(
            firstDiscoveredDate: now,
            firstDiscoveredVersion: "3.0",
            events: [.discovered(date: now, installedVersion: "3.0")]
        )
        let decoded = try decoder.decode(LabelHistory.self, from: try encoder.encode(history))

        #expect(abs(decoded.firstDiscoveredDate.timeIntervalSince(now)) < 1.0)
        #expect(abs(decoded.events[0].date.timeIntervalSince(now)) < 1.0)
    }

    @Test func labelHistoryRoundTripEmptyEvents() throws {
        let history = LabelHistory(firstDiscoveredDate: Date(), firstDiscoveredVersion: "1.0", events: [])
        let decoded = try decoder.decode(LabelHistory.self, from: try encoder.encode(history))
        #expect(decoded.events.isEmpty)
    }
}


// MARK: - LabelHistory persistence (requires PATCHER_DATA_DIR)

struct LabelHistoryPersistenceTests {

    // Uses a UUID label name so tests are isolated from each other
    private func uniqueLabel() -> String { "test-\(UUID().uuidString)" }

    @Test func recordDiscoveredCreatesHistoryFile() {
        let label = uniqueLabel()
        recordDiscoveredIfNeeded(label: label, installedVersion: "1.0", date: Date())

        let history = LabelHistory.load(label: label)
        #expect(history != nil)
        #expect(history?.firstDiscoveredVersion == "1.0")
        #expect(history?.events.count == 1)
        #expect(history?.events.first?.type == LabelHistoryEvent.EventType.discovered)
    }

    @Test func recordDiscoveredIsIdempotent() {
        let label = uniqueLabel()
        let date  = Date()
        recordDiscoveredIfNeeded(label: label, installedVersion: "1.0", date: date)
        recordDiscoveredIfNeeded(label: label, installedVersion: "1.0", date: date)
        recordDiscoveredIfNeeded(label: label, installedVersion: "1.0", date: date)

        // Only one event should exist regardless of how many times called
        #expect(LabelHistory.load(label: label)?.events.count == 1)
    }

    @Test func recordUpdateFoundAppendsEvent() {
        let label = uniqueLabel()
        let date  = Date()
        recordDiscoveredIfNeeded(label: label, installedVersion: "1.0", date: date)
        recordUpdateFoundIfNeeded(label: label, installedVersion: "1.0", availableVersion: "2.0", date: date)

        let history = LabelHistory.load(label: label)
        #expect(history?.events.count == 2)
        #expect(history?.lastEvent(ofType: LabelHistoryEvent.EventType.updateFound)?.availableVersion == "2.0")
    }

    @Test func recordUpdateFoundDeduplicatesSameVersion() {
        let label = uniqueLabel()
        let date  = Date()
        recordDiscoveredIfNeeded(label: label, installedVersion: "1.0", date: date)
        recordUpdateFoundIfNeeded(label: label, installedVersion: "1.0", availableVersion: "2.0", date: date)
        recordUpdateFoundIfNeeded(label: label, installedVersion: "1.0", availableVersion: "2.0", date: date)

        let updateEvents = LabelHistory.load(label: label)?.events
            .filter { $0.type == LabelHistoryEvent.EventType.updateFound }
        #expect(updateEvents?.count == 1)
    }

    @Test func recordUpdateFoundAllowsNewVersion() {
        let label = uniqueLabel()
        let date  = Date()
        recordDiscoveredIfNeeded(label: label, installedVersion: "1.0", date: date)
        recordUpdateFoundIfNeeded(label: label, installedVersion: "1.0", availableVersion: "2.0", date: date)
        recordUpdateFoundIfNeeded(label: label, installedVersion: "2.0", availableVersion: "3.0", date: date)

        let updateEvents = LabelHistory.load(label: label)?.events
            .filter { $0.type == LabelHistoryEvent.EventType.updateFound }
        #expect(updateEvents?.count == 2)
        #expect(updateEvents?.last?.availableVersion == "3.0")
    }

    @Test func recordUpdateFoundIgnoresEmptyAvailableVersion() {
        let label = uniqueLabel()
        let date  = Date()
        recordDiscoveredIfNeeded(label: label, installedVersion: "1.0", date: date)
        recordUpdateFoundIfNeeded(label: label, installedVersion: "1.0", availableVersion: "", date: date)

        // Empty availableVersion is a no-op — only the discovered event should exist
        #expect(LabelHistory.load(label: label)?.events.count == 1)
    }
}


// MARK: - DeferralState persistence (requires PATCHER_DATA_DIR)

struct DeferralStatePersistenceTests {

    // Resets the on-disk state before and after each test to prevent cross-test pollution.
    // Both are best-effort — we don't fail the test if cleanup itself fails.
    private func withCleanDeferralState(_ body: () -> Void) {
        var clean = DeferralState(); clean.reset(); clean.save()
        body()
        var cleanup = DeferralState(); cleanup.reset(); cleanup.save()
    }

    @Test func saveThenLoadPreservesActiveDeferral() {
        withCleanDeferralState {
            var state = DeferralState()
            state.recordDeferral(minutes: 120)
            state.save()

            let loaded = DeferralState.load()
            #expect(loaded.count == 1)
            #expect(loaded.isActive())
            #expect(loaded.remainingMinutes() > 0)
        }
    }

    @Test func saveThenLoadAfterResetIsInactive() {
        withCleanDeferralState {
            var state = DeferralState()
            state.recordDeferral(minutes: 120)
            state.save()

            var loaded = DeferralState.load()
            loaded.reset()
            loaded.save()

            let reloaded = DeferralState.load()
            #expect(!reloaded.isActive())
            #expect(reloaded.count == 0)
        }
    }

    @Test func loadReturnsInactiveWhenNoFileExists() {
        withCleanDeferralState {
            // withCleanDeferralState resets to a fresh state with count=0, expiryDate=nil
            let loaded = DeferralState.load()
            #expect(!loaded.isActive())
            #expect(loaded.count == 0)
        }
    }
}

// MARK: - DialogText

struct DialogTextTests {

    /// patcher has no Dialogs table, so the typed values word themselves as the English
    /// the windows showed before.
    @Test func progressDetailEnglish() {
        #expect(ProgressDetail.downloading(fraction: 0.456, received: nil, total: nil).text == "Downloading 45%")
        #expect(ProgressDetail.downloading(fraction: nil, received: nil, total: nil).text == "Downloading…")
        #expect(ProgressDetail.downloading(fraction: nil, received: 0, total: nil).text == "Downloading…")
        #expect(ProgressDetail.downloading(fraction: nil, received: 5_000_000, total: nil).text.hasPrefix("Downloading · "))
        let full = ProgressDetail.downloading(fraction: 0.5, received: 49_000_000, total: 98_000_000).text
        #expect(full.hasPrefix("Downloading 50% · ") && full.contains(" of "))
        #expect(ProgressDetail.installing(fraction: 0.999).text == "Installing 99%")
        #expect(ProgressDetail.installing(fraction: 1).text == "Installing 100%")
        #expect(ProgressDetail.copying(fraction: 0).text == "Copying 0%")
        #expect(ProgressDetail.openingDiskImage.text == "Opening disk image…")
        #expect(ProgressDetail.extracting.text == "Extracting…")
    }

    @Test func progressFractionIsClamped() {
        #expect(ProgressDetail.downloading(fraction: 1.2, received: nil, total: nil).fraction == 1)
        #expect(ProgressDetail.installing(fraction: -0.1).fraction == 0)
        #expect(ProgressDetail.extracting.fraction == nil)
    }

    @Test func skipReasonEnglish() {
        #expect(SkipReason.appRunning.text == "App running")
        #expect(SkipReason.unavailableDrive.text == "Unavailable Drive")
        #expect(SkipReason.waitingForUser.text == "Waiting for user…")
    }

    @Test func paragraphsJoinWithBlankLines() {
        let text = DialogText.paragraphs([.verbatim("One."), .skipped(.screenLocked)]).text
        #expect(text == "One.\n\nScreen locked")
    }

    private func item(detail: DialogText) -> DialogSession.Item {
        DialogSession.Item(id: "zoom", title: "Zoom", subtitle: nil, icon: nil,
                           status: .skipped, statusDetail: detail)
    }

    @Test func itemRoundTripsTypedStatus() throws {
        let original = item(detail: .skipped(.waitingForUser))
        let decoded = try JSONDecoder().decode(DialogSession.Item.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
        #expect(decoded.statusDetail == .skipped(.waitingForUser))
    }

    /// Messages whose English doesn't depend on a plural (the catalog's singular forms
    /// come from PatcherNotifier.app, which tests can't rely on being installed).
    @Test func messagesEnglish() {
        #expect(DialogText.updateOfTotal(current: 2, total: 5).text == "Update 2 of 5")
        #expect(DialogText.withDetail(.updateOfTotal(current: 2, total: 5), .progress(.installing(fraction: 0.45))).text
                == "Update 2 of 5 · Installing 45%")
        #expect(DialogText.installingApp(app: "Zoom", version: "6.1").text == "Installing: Zoom → 6.1…")
        #expect(DialogText.installingApp(app: "Zoom", version: "").text == "Installing: Zoom…")
        #expect(DialogText.updatedApp(app: "Zoom", version: nil).text == "✅ Updated: Zoom")
        #expect(DialogText.skippedApp(app: "Zoom", reason: .appRunning).text == "⚠️ Zoom — App running")
        #expect(DialogText.completeSummary(applied: 3, skipped: 1, failed: 0).text == "Complete — 3 updated · 1 skipped")
        #expect(DialogText.completeSummary(applied: 3, skipped: 1, failed: 2).text
                == "Complete — 3 updated · 1 skipped · 2 failed")
        #expect(DialogText.quitApp(process: "zoom.us").text == "Quit zoom.us")
        #expect(DialogText.updatePausedTitle(app: "Zoom").text == "Zoom Update Paused")
        #expect(DialogText.deferralStatus(daysPending: 4, userDeferrals: 2, autoDeferrals: 1).text
                == "**Deferral Status**\nDays pending: 4\nUser deferrals: 2\nAuto deferrals: 1")
        #expect(DialogText.deferralStatus(daysPending: 4, userDeferrals: 2, autoDeferrals: 1, deadline: Date())
                .text.hasPrefix("**Deferral Status**\nDays pending: 4\nUser deferrals: 2\nAuto deferrals: 1\n\n**Deadline**\n"))
        #expect(DialogText.deadlineDaysLeft(days: 3).text == "**3 days** left to defer")
        #expect(DialogText.deadlineHoursLeft(hours: 5).text == "**5 hours** left to defer")
    }

    @Test func deadlineBadgeEscalates() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        func at(hours: Double) -> DialogSession.Deadline {
            DialogSession.Deadline(date: now.addingTimeInterval(hours * 3600), reached: false)
        }
        #expect(at(hours: 24 * 10).urgency(now: now) == .none)
        #expect(at(hours: 24 * 10).badgeText(now: now) == nil)
        #expect(at(hours: 24 * 7 + 1).urgency(now: now) == .notice)
        #expect(at(hours: 24 * 7 + 1).badgeText(now: now) == .deadlineDaysLeft(days: 7))
        #expect(at(hours: 24 * 3 + 1).urgency(now: now) == .warning)
        #expect(at(hours: 23).urgency(now: now) == .critical)
        #expect(at(hours: 23).badgeText(now: now) == .deadlineHoursLeft(hours: 23))
        #expect(at(hours: 0.5).badgeText(now: now) == .deadlineUnderAnHour)
        #expect(at(hours: -1).badgeText(now: now) == .deadlinePassed)
        // patcher's decision wins over the clock, and needs no date.
        let reached = DialogSession.Deadline(date: nil, reached: true)
        #expect(reached.urgency(now: now) == .critical)
        #expect(reached.badgeText(now: now) == .deadlinePassed)
        #expect(DialogSession.Deadline(date: nil, reached: false).urgency(now: now) == .none)
    }

    @Test func listsAndDurations() {
        #expect(DialogText.duration(minutes: 120).text == "2 hours")
        #expect(DialogText.duration(minutes: 90).text.hasPrefix("1 hour"))
        #expect(DialogText.shortDuration(minutes: 90).text.count < DialogText.duration(minutes: 90).text.count)
        #expect(DialogText.appsDeferred(names: ["Zoom"], minutes: 60).text == "Zoom is deferred for 1 hour.")
        #expect(DialogText.appsDeferred(names: ["Zoom", "Slack"], minutes: 120).text
                == "Zoom and Slack are deferred for 2 hours.")
        #expect(DialogText.deferredFor(minutes: 30).text == "Deferred · 30 minutes")
    }

    @Test func sentencesAndParagraphsSkipEmptyParts() {
        #expect(DialogText.sentences([.uncheckToPutOff, .verbatim(""), .installationRequired]).text
                == "Uncheck any you’d like to put off. **Installation is required** — the maximum deferral deadline has been reached.")
        #expect(DialogText.paragraphs([.updatesBeingAttempted, .verbatim("")]).text == "These updates are being attempted.")
    }

    private func session() -> DialogSession {
        DialogSessionWriter.makeSession(kind: .applyList, uid: 501, prefs: Preferences(), position: "center",
                                        title: .verbatim("Acme Updates"), message: .updatesBeingAttempted, total: 2)
    }

    @Test func sessionRoundTripsTypedText() throws {
        var s = session()
        s.sidePanel = .paragraphs([.updatesWaiting(count: 3), .appsDeferred(names: ["Zoom"], minutes: 60)])
        s.menu = DialogSession.Menu(title: .deferForMenu,
                                    options: [.init(value: "60", label: .duration(minutes: 60))], selected: "60")
        s.help = makeHelp(prefs: Preferences(), started: Date(timeIntervalSince1970: 1_800_000_000))
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(DialogSession.self, from: encoder.encode(s))
        // (Dates lose fractional seconds in ISO 8601, so compare the text, not the whole session.)
        #expect(decoded.title == s.title)
        #expect(decoded.message == s.message)
        #expect(decoded.sidePanel == s.sidePanel)
        #expect(decoded.menu == s.menu)
        #expect(decoded.help == s.help)
        #expect(decoded.help?.computer.last?.value == .date(Date(timeIntervalSince1970: 1_800_000_000)))
    }

    /// Sessions carry typed text only; PatcherNotifier words it.
    @Test func sessionCarriesNoEnglish() throws {
        var s = session()
        s.button = DialogSession.Button(.done, enabled: true)
        s.items  = [item(detail: .waiting)]
        let json = String(decoding: try JSONEncoder().encode(s), as: UTF8.self)
        #expect(!json.contains("These updates are being attempted"))
        #expect(!json.contains("\"Done\""))
        #expect(!json.contains("statusText"))
    }

    // MARK: Notifications

    @Test func notificationMessagesEnglish() {
        #expect(DialogText.appWasUpdated(app: "Zoom", version: "6.1", background: false).text
                == "Zoom was updated to version 6.1.")
        #expect(DialogText.appWasUpdated(app: "Zoom", version: nil, background: true).text
                == "Zoom was updated in the background.")
        #expect(DialogText.appList(["Zoom 6.1", "Slack", "Firefox 140"]).text
                == "Zoom 6.1, Slack, and Firefox 140")
        let prompt = DialogText.quitAndUpdatePrompt(process: "zoom.us", seconds: 300).text
        #expect(prompt.contains("quit zoom.us yourself"))
        #expect(prompt.contains("in 5 minutes."))
    }

    private func encodedEvent() throws -> [String: Any] {
        let event = PatcherNotificationEvent(kind: .applyInstalled, title: .appUpdatedTitle(app: "Zoom"),
                                             body: .appWasUpdated(app: "Zoom", version: "6.1", background: false),
                                             threadID: "apply")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try JSONSerialization.jsonObject(with: encoder.encode(event)) as! [String: Any]
    }

    private func decodeEvent(_ object: [String: Any]) throws -> PatcherNotificationEvent {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(PatcherNotificationEvent.self,
                                  from: JSONSerialization.data(withJSONObject: object))
    }

    @Test func notificationEventCarriesTypedText() throws {
        let object = try encodedEvent()
        #expect(object["title"] is [String: Any])
        let decoded = try decodeEvent(object)
        #expect(decoded.title == .appUpdatedTitle(app: "Zoom"))
        #expect(decoded.body.text == "Zoom was updated to version 6.1.")
    }

    @Test func liveStatusRoundTripsThroughJSONObject() {
        let status = DialogText.progress(.installing(fraction: 0.3))
        #expect(DialogText(jsonObject: status.jsonObject) == status)
        #expect(DialogText(jsonObject: DialogText.scanning.jsonObject)?.text == "Scanning…")
        #expect(DialogText(jsonObject: nil) == nil)
        #expect(DialogText(jsonObject: ["someFutureStatus": [:]]) == nil)
    }
}

// MARK: - DuplicateLabels

struct DuplicateLabelsTests {

    private let onedrive = DuplicateLabels.Group(
        id: "onedrive", preferred: "microsoftonedrive",
        members: ["microsoftonedrive", "microsoftonedrive-deferred", "microsoftonedrivesuprod"])
    private let firefox = DuplicateLabels.Group(
        id: "firefox", preferred: "firefoxpkg",
        members: ["firefox", "firefox_intl", "firefoxesr", "firefoxpkg"])

    private func select(_ groups: [DuplicateLabels.Group], all: [String], required: [String] = [],
                        preferPkg: Bool = true) -> DuplicateLabels.Selection {
        DuplicateLabels.selection(groups: groups, allLabels: Set(all), required: Set(required),
                                  preferPkgLabels: preferPkg)
    }

    @Test func keepsPreferredAndIgnoresTheRest() {
        let result = select([onedrive], all: onedrive.members + ["zoom"])
        #expect(Set(result.ignored) == ["microsoftonedrive-deferred", "microsoftonedrivesuprod"])
        #expect(result.notes.isEmpty)
    }

    @Test func requiredMemberReplacesPreferred() {
        let result = select([onedrive], all: onedrive.members, required: ["microsoftonedrivesuprod"])
        #expect(Set(result.ignored) == ["microsoftonedrive", "microsoftonedrive-deferred"])
        #expect(result.notes.count == 1)
    }

    @Test func requiringPreferredChangesNothing() {
        let result = select([onedrive], all: onedrive.members, required: ["microsoftonedrive"])
        #expect(Set(result.ignored) == ["microsoftonedrive-deferred", "microsoftonedrivesuprod"])
        #expect(result.notes.isEmpty)
    }

    @Test func everyRequiredMemberIsKept() {
        let result = select([onedrive], all: onedrive.members,
                            required: ["microsoftonedrive-deferred", "microsoftonedrivesuprod"])
        #expect(result.ignored == ["microsoftonedrive"])
    }

    @Test func preferredFollowsPreferPkgLabelsOff() {
        let result = select([firefox], all: firefox.members, preferPkg: false)
        #expect(Set(result.ignored) == ["firefox_intl", "firefoxesr", "firefoxpkg"])
    }

    @Test func preferredFollowsPreferPkgLabelsOn() {
        let group = DuplicateLabels.Group(id: "bbedit", preferred: "bbedit", members: ["bbedit", "bbeditpkg", "bbeditlegacy"])
        let result = select([group], all: group.members, preferPkg: true)
        #expect(Set(result.ignored) == ["bbedit", "bbeditlegacy"])
    }

    @Test func onlyPresentMembersCount() {
        let result = select([onedrive], all: ["microsoftonedrive", "microsoftonedrivesuprod"])
        #expect(result.ignored == ["microsoftonedrivesuprod"])
    }

    @Test func groupWithOnePresentMemberIsSkipped() {
        #expect(select([onedrive], all: ["microsoftonedrivesuprod"]).ignored.isEmpty)
    }

    @Test func missingPreferredLeavesGroupAlone() {
        let result = select([onedrive], all: ["microsoftonedrive-deferred", "microsoftonedrivesuprod"])
        #expect(result.ignored.isEmpty)
        #expect(result.notes.count == 1)
    }

    @Test func parsesSchemaOneAndSkipsMalformedGroups() {
        let json = """
        {"schemaVersion": 1, "groups": [
          {"id": "a", "preferred": "a1", "members": ["a1", "a2"]},
          {"id": "b", "preferred": "zz", "members": ["b1", "b2"]},
          {"preferred": "c1", "members": ["c1", "c2"]}
        ]}
        """
        let groups = DuplicateLabels.parse(Data(json.utf8))
        #expect(groups == [DuplicateLabels.Group(id: "a", preferred: "a1", members: ["a1", "a2"])])
    }

    @Test func rejectsOtherSchemaVersions() {
        #expect(DuplicateLabels.parse(Data(#"{"schemaVersion": 2, "groups": []}"#.utf8)) == nil)
        #expect(DuplicateLabels.parse(Data("not json".utf8)) == nil)
    }

    @Test func builtInSnapshotParses() {
        let groups = DuplicateLabels.parse(Data(DuplicateLabelsSnapshot.json.utf8))
        #expect((groups?.count ?? 0) > 0)
        #expect(groups?.contains { $0.id == "onedrive" && $0.preferred == "microsoftonedrive" } == true)
    }
}
