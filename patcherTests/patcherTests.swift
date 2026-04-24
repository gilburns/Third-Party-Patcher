//
//  patcherTests.swift
//  patcherTests
//
//  Tests for pure patcher logic — no process launching, no disk I/O,
//  no swiftDialog UI interaction.
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
        #expect(UpdateStatus(rawValue: "upToDate")       == .upToDate)
        #expect(UpdateStatus(rawValue: "wouldDowngrade") == .wouldDowngrade)
        #expect(UpdateStatus(rawValue: "unknown")        == .unknown)
    }

    @Test func invalidRawValueReturnsNil() {
        #expect(UpdateStatus(rawValue: "bogus") == nil)
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
