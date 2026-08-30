import Foundation
import XCTest
@testable import ChiboardTelemetry

final class TelemetryTests: XCTestCase {
    func testUnsetConsentIsOffAndDoesNotCreateIdentifier() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        var backendCreations = 0
        let client = TelemetryClient(
            consentStore: fixture.store,
            bundle: Bundle(for: TelemetryTests.self),
            processEnvironment: [
                "CHIBOARD_TELEMETRY_TEST_OVERRIDE": "1",
                "CHIBOARD_TELEMETRY_COLLECTOR_URL": "https://collector.example.invalid/events",
            ],
            now: Date.init,
            backendFactory: {
                backendCreations += 1
                return RecordingTelemetryBackend()
            }
        )

        XCTAssertEqual(fixture.store.state, .unset)
        XCTAssertFalse(fixture.store.state.permitsCollection)
        XCTAssertNil(fixture.store.installationID)
        XCTAssertNil(fixture.store.installationIDCreatingIfNeeded())
        client.start(role: .inputMethod)
        client.record(.usage(.conversionsStarted))
        XCTAssertTrue(client.stop(timeout: 1))
        XCTAssertEqual(backendCreations, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cacheRoot.path))
    }

    func testConsentPersistsAndIdentifierResets() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }

        let first = try XCTUnwrap(fixture.store.setState(.enabled))
        XCTAssertEqual(fixture.store.state, .enabled)
        XCTAssertEqual(fixture.store.installationID, first)
        XCTAssertEqual(fixture.store.privacyNoticeVersion, 1)

        let reloaded = TelemetryConsentStore(
            defaults: fixture.defaults,
            cacheRootURL: fixture.cacheRoot
        )
        XCTAssertEqual(reloaded.installationID, first)

        reloaded.setState(.disabled)
        XCTAssertEqual(fixture.store.state, .disabled)
        XCTAssertNil(fixture.store.installationID)

        let second = try XCTUnwrap(reloaded.setState(.enabled))
        XCTAssertNotEqual(first, second)
    }

    func testConsentChangeIsDistributed() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        let changed = expectation(description: "distributed consent change")
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: TelemetryConsentStore.changedNotification,
            object: nil,
            queue: .main
        ) { _ in changed.fulfill() }
        defer { DistributedNotificationCenter.default().removeObserver(observer) }

        fixture.store.setState(.enabled)

        wait(for: [changed], timeout: 2)
    }

    func testDistributedOptOutStopsEveryRunningProcess() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        fixture.store.setState(.enabled)
        let secondStore = TelemetryConsentStore(
            defaults: fixture.defaults,
            cacheRootURL: fixture.cacheRoot
        )
        let started = expectation(description: "both telemetry processes started")
        started.expectedFulfillmentCount = 2
        let stopped = expectation(description: "both telemetry processes stopped")
        stopped.expectedFulfillmentCount = 2
        let firstBackend = RecordingTelemetryBackend(
            onStart: { started.fulfill() },
            onStop: { stopped.fulfill() }
        )
        let secondBackend = RecordingTelemetryBackend(
            onStart: { started.fulfill() },
            onStop: { stopped.fulfill() }
        )
        let firstClient = makeEnabledClient(
            store: fixture.store,
            backend: firstBackend
        )
        let secondClient = makeEnabledClient(
            store: secondStore,
            backend: secondBackend
        )

        firstClient.start(role: .inputMethod)
        secondClient.start(role: .shortcuts)
        wait(for: [started], timeout: 2)

        // This represents a third process changing the shared preference.
        // Both live clients must react to the distributed notification.
        fixture.store.setState(.disabled)
        wait(for: [stopped], timeout: 2)
        XCTAssertTrue(firstClient.stop(timeout: 1))
        XCTAssertTrue(secondClient.stop(timeout: 1))

        XCTAssertEqual(firstBackend.stopCount, 1)
        XCTAssertEqual(secondBackend.stopCount, 1)
        XCTAssertNil(fixture.store.installationID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cacheRoot.path))
    }

    func testMissingConfigurationIsANoOp() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        fixture.store.setState(.enabled)
        var backendCreations = 0
        let client = TelemetryClient(
            consentStore: fixture.store,
            bundle: Bundle(for: TelemetryTests.self),
            processEnvironment: ["CHIBOARD_TELEMETRY_TEST_OVERRIDE": "1"],
            now: Date.init,
            backendFactory: {
                backendCreations += 1
                return RecordingTelemetryBackend()
            }
        )

        client.start(role: .setup)
        XCTAssertTrue(client.stop(timeout: 1))

        XCTAssertEqual(backendCreations, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cacheRoot.path))
    }

    func testAllProcessRolesStartAndAggregateOnlyCounters() throws {
        for role in TelemetryProcessRole.allCases {
            let fixture = try makeFixture()
            defer { fixture.cleanUp() }
            fixture.store.setState(.enabled)
            let backend = RecordingTelemetryBackend()
            let client = makeEnabledClient(
                store: fixture.store,
                backend: backend,
                now: { Date(timeIntervalSince1970: 10_000) }
            )

            client.start(role: role)
            client.record(.usage(.conversionsStarted, count: 2))
            client.record(.usage(.candidateRequests))
            XCTAssertTrue(client.stop(timeout: 1))

            XCTAssertEqual(backend.configurations.map(\.role), [role])
            XCTAssertEqual(backend.records.count, 1)
            XCTAssertEqual(backend.records.first?.name, .usageSummary)
            XCTAssertEqual(backend.value(for: .conversionsStarted), "2")
            XCTAssertEqual(backend.value(for: .candidateRequests), "1")
            XCTAssertEqual(backend.stopCount, 1)
        }
    }

    func testOptOutStopsBackendBeforePurgingIdentifierAndCache() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        fixture.store.setState(.enabled)
        let cache = fixture.store.cacheURL(for: .inputMethod)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data("queued".utf8).write(to: cache.appendingPathComponent("report"))
        let backend = RecordingTelemetryBackend()
        let client = makeEnabledClient(store: fixture.store, backend: backend)

        client.start(role: .inputMethod)
        client.setConsent(.disabled)
        XCTAssertTrue(client.stop(timeout: 1))

        XCTAssertEqual(backend.stopCount, 1)
        XCTAssertEqual(fixture.store.state, .disabled)
        XCTAssertNil(fixture.store.installationID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.cacheRoot.path))
    }

    func testShutdownWaitIsBounded() throws {
        let fixture = try makeFixture()
        defer { fixture.cleanUp() }
        fixture.store.setState(.enabled)
        let backend = RecordingTelemetryBackend(stopDelay: 0.15)
        let client = makeEnabledClient(store: fixture.store, backend: backend)
        client.start(role: .shortcuts)
        client.record(.usage(.shortcutAttempts))

        let started = Date()
        XCTAssertFalse(client.stop(timeout: 0.01))
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.1)
        XCTAssertTrue(client.stop(timeout: 1))
    }

    func testConversionSuccessRateExcludesStaleAndCancellations() {
        let summary = TelemetryUsageSummary(
            conversionsStarted: 20,
            conversionsApplied: 7,
            conversionsFailed: 2,
            conversionsRejected: 1,
            conversionsStale: 10
        )
        XCTAssertEqual(summary.conversionSuccessRate ?? -1, 0.7, accuracy: 0.000_001)
        XCTAssertNil(TelemetryUsageSummary(conversionsStale: 4).conversionSuccessRate)
    }

    func testSerializedEventSnapshots() throws {
        let context = TelemetryRecordContext(
            role: .inputMethod,
            release: "1.2.3+45",
            macOSVersion: "14.6",
            environment: .production
        )
        let usage = TelemetryRecordFactory.make(
            event: .usageSummary(.init(
                windowSeconds: 1_800,
                conversionsStarted: 12,
                conversionsApplied: 7,
                conversionsFailed: 2,
                conversionsRejected: 1,
                conversionsStale: 4,
                candidateRequests: 3,
                candidateApplies: 2,
                shortcutAttempts: 5,
                shortcutSuccesses: 4
            )),
            context: context
        )
        XCTAssertEqual(
            usage.canonicalJSON,
            try fixtureJSON(named: "usage-summary")
        )

        let model = TelemetryRecordFactory.make(
            event: .modelLoadResult(
                success: false,
                backend: .metal,
                loadMilliseconds: 321,
                errorCode: .engineLoadFailed
            ),
            context: context
        )
        XCTAssertEqual(
            model.canonicalJSON,
            try fixtureJSON(named: "model-load-result")
        )

        let setup = TelemetryRecordFactory.make(
            event: .setupMilestone(.inputSourceEnabled, result: .success),
            context: context
        )
        XCTAssertEqual(
            setup.canonicalJSON,
            try fixtureJSON(named: "setup-milestone")
        )

        let crash = TelemetryRecord(name: .crash, fields: [
            .init(key: .schemaVersion, value: "1"),
            .init(key: .processRole, value: "input_method"),
            .init(key: .release, value: "1.2.3+45"),
            .init(key: .macOSVersion, value: "14.6"),
            .init(key: .environment, value: "prod"),
            .init(key: .crashID, value: "123e4567-e89b-42d3-a456-426614174000"),
            .init(key: .signalName, value: "SIGABRT"),
            .init(key: .signalCode, value: "0"),
            .init(key: .rawSignature, value: String(repeating: "0", count: 64)),
            .init(key: .frameCount, value: "1"),
            .init(
                key: .frames,
                value: #"[{"image_kind":"app","image_offset":4096,"image_uuid":"123e4567-e89b-42d3-a456-426614174000"}]"#
            ),
        ])
        XCTAssertEqual(crash.canonicalJSON, try fixtureJSON(named: "crash"))
    }

    func testEventContractHasOnlyAllowlistedFieldsAndNoSensitiveNames() throws {
        let allowed = Set([
            "schema_version", "process_role", "release", "macos_version", "environment",
            "window_seconds", "conversions_started", "conversions_applied",
            "conversions_failed", "conversions_rejected", "conversions_stale",
            "candidate_requests", "candidate_applies", "shortcut_attempts",
            "shortcut_successes", "success", "backend", "load_milliseconds",
            "error_code", "milestone", "result", "event",
            "crash_id", "signal_name", "signal_code", "raw_signature",
            "frame_count", "frames",
        ])
        let banned = Set([
            "text", "typed_text", "pinyin", "context", "key_data", "path",
            "filename", "bundle_id", "client_bundle_id", "custom_term",
            "custom_term_id", "diagnostic", "log_message", "error_message",
            "username", "user_id", "url", "request", "response",
        ])
        let context = TelemetryRecordContext(
            role: .setup,
            release: "1.0+1",
            macOSVersion: "15.0",
            environment: .test
        )
        let records = [
            TelemetryRecordFactory.make(
                event: .usageSummary(.init(conversionsStarted: 1)),
                context: context
            ),
            TelemetryRecordFactory.make(
                event: .modelLoadResult(
                    success: true,
                    backend: .cpu,
                    loadMilliseconds: 8,
                    errorCode: .none
                ),
                context: context
            ),
            TelemetryRecordFactory.make(
                event: .setupMilestone(.tutorialComplete, result: .skipped),
                context: context
            ),
        ]

        XCTAssertEqual(Set(TelemetryRecordName.allCases), [
            .usageSummary, .modelLoadResult, .setupMilestone, .crash,
        ])
        for record in records {
            let data = try XCTUnwrap(record.canonicalJSON.data(using: .utf8))
            let object = try XCTUnwrap(
                JSONSerialization.jsonObject(with: data) as? [String: String]
            )
            XCTAssertTrue(Set(object.keys).isSubset(of: allowed))
            XCTAssertTrue(Set(object.keys).isDisjoint(with: banned))
        }
    }

    func testReleaseAndOSValuesAreSanitized() {
        let context = TelemetryRecordContext(
            role: .setup,
            release: "secret/path",
            macOSVersion: "14.4 beta",
            environment: .test
        )
        XCTAssertEqual(context.release, "unknown")
        XCTAssertEqual(context.macOSVersion, "unknown")
    }

    func testBundledPrivacyNoticesAreLocalizedAndComplete() {
        let english = TelemetryPrivacyNotice.text(language: .english)
        let chinese = TelemetryPrivacyNotice.text(language: .simplifiedChinese)

        XCTAssertTrue(english.contains("anything you type"))
        XCTAssertTrue(english.contains("30 days"))
        XCTAssertTrue(english.contains("johnbean393@gmail.com"))
        XCTAssertTrue(chinese.contains("阿里云"))
        XCTAssertTrue(chinese.contains("输入内容"))
        XCTAssertTrue(chinese.contains("johnbean393@gmail.com"))
        XCTAssertNotNil(TelemetryPrivacyNotice.privacyManifestURL)
    }

    private func fixtureJSON(named name: String) throws -> String {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(
            contentsOf: packageRoot
                .appendingPathComponent("Contract/Fixtures", isDirectory: true)
                .appendingPathComponent(name)
                .appendingPathExtension("json")
        )
        let object = try JSONSerialization.jsonObject(with: data)
        let canonical = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return try XCTUnwrap(String(data: canonical, encoding: .utf8))
    }

    private func makeEnabledClient(
        store: TelemetryConsentStore,
        backend: RecordingTelemetryBackend,
        now: @escaping () -> Date = Date.init
    ) -> TelemetryClient {
        TelemetryClient(
            consentStore: store,
            bundle: Bundle(for: TelemetryTests.self),
            processEnvironment: [
                "CHIBOARD_TELEMETRY_TEST_OVERRIDE": "1",
                "CHIBOARD_TELEMETRY_COLLECTOR_URL": "https://collector.example.invalid/events",
            ],
            now: now,
            backendFactory: { backend }
        )
    }

    private func makeFixture() throws -> TelemetryFixture {
        let suiteName = "com.chiboard.tests.telemetry.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChiboardTelemetryTests")
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return TelemetryFixture(
            suiteName: suiteName,
            defaults: defaults,
            cacheRoot: root,
            store: TelemetryConsentStore(defaults: defaults, cacheRootURL: root)
        )
    }
}

private struct TelemetryFixture {
    let suiteName: String
    let defaults: UserDefaults
    let cacheRoot: URL
    let store: TelemetryConsentStore

    func cleanUp() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: cacheRoot)
    }
}

private final class RecordingTelemetryBackend: TelemetryBackend {
    private let stopDelay: TimeInterval
    private let onStart: (() -> Void)?
    private let onStop: (() -> Void)?
    private(set) var configurations: [TelemetryBackendConfiguration] = []
    private(set) var records: [TelemetryRecord] = []
    private(set) var flushCount = 0
    private(set) var stopCount = 0

    init(
        stopDelay: TimeInterval = 0,
        onStart: (() -> Void)? = nil,
        onStop: (() -> Void)? = nil
    ) {
        self.stopDelay = stopDelay
        self.onStart = onStart
        self.onStop = onStop
    }

    func start(configuration: TelemetryBackendConfiguration) -> Bool {
        configurations.append(configuration)
        onStart?()
        return true
    }

    func report(_ record: TelemetryRecord) {
        records.append(record)
    }

    func flush() {
        flushCount += 1
    }

    func stop() {
        if stopDelay > 0 { Thread.sleep(forTimeInterval: stopDelay) }
        stopCount += 1
        onStop?()
    }

    func value(for key: TelemetryFieldKey) -> String? {
        records.last?.fields.first(where: { $0.key == key })?.value
    }
}
