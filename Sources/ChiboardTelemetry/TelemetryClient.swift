import Foundation

struct TelemetryRuntimeConfiguration: Equatable {
    static let enabledInfoKey = "ChiboardTelemetryEnabled"
    static let collectorURLInfoKey = "ChiboardTelemetryCollectorURL"

    let collectorURL: URL
    let environment: TelemetryEnvironment

    static func load(
        bundle: Bundle,
        processEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TelemetryRuntimeConfiguration? {
        let testOverride = processEnvironment["CHIBOARD_TELEMETRY_TEST_OVERRIDE"] == "1"
        #if DEBUG
        guard testOverride else { return nil }
        #endif

        let enabled: Bool
        if testOverride {
            enabled = true
        } else if let value = bundle.object(forInfoDictionaryKey: enabledInfoKey) as? Bool {
            enabled = value
        } else if let value = bundle.object(forInfoDictionaryKey: enabledInfoKey) as? String {
            enabled = ["1", "YES", "TRUE"].contains(value.uppercased())
        } else {
            enabled = false
        }
        guard enabled else { return nil }

        let value = testOverride
            ? processEnvironment["CHIBOARD_TELEMETRY_COLLECTOR_URL"]
            : bundle.object(forInfoDictionaryKey: collectorURLInfoKey) as? String
        guard let normalized = normalizedPublicConfiguration(value),
              let collectorURL = URL(string: normalized),
              collectorURL.scheme?.lowercased() == "https",
              collectorURL.host != nil,
              collectorURL.user == nil,
              collectorURL.password == nil,
              collectorURL.fragment == nil else {
            return nil
        }
        return .init(
            collectorURL: collectorURL,
            environment: testOverride ? .test : .production
        )
    }

    private static func normalizedPublicConfiguration(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty,
              !normalized.contains("$("),
              normalized.count <= 1_024 else { return nil }
        return normalized
    }
}

public final class TelemetryClient: TelemetryReporting, @unchecked Sendable {
    public static let shared = TelemetryClient()
    public static let aggregationInterval: TimeInterval = 30 * 60

    private let queue: DispatchQueue
    private let consentStore: TelemetryConsentStore
    private let bundle: Bundle
    private let processEnvironment: [String: String]
    private let now: () -> Date
    private let backendFactory: () -> TelemetryBackend

    private var role: TelemetryProcessRole?
    private var backend: TelemetryBackend?
    private var context: TelemetryRecordContext?
    private var counters = TelemetryUsageSummary()
    private var windowStartedAt: Date?
    private var timer: DispatchSourceTimer?
    private var consentObserver: NSObjectProtocol?
    private var crashCapture: TelemetryCrashCapture?

    public convenience init(consentStore: TelemetryConsentStore = TelemetryConsentStore()) {
        self.init(
            consentStore: consentStore,
            bundle: .main,
            processEnvironment: ProcessInfo.processInfo.environment,
            now: Date.init,
            backendFactory: { CollectorTelemetryBackend() }
        )
    }

    init(
        consentStore: TelemetryConsentStore,
        bundle: Bundle,
        processEnvironment: [String: String],
        now: @escaping () -> Date,
        backendFactory: @escaping () -> TelemetryBackend
    ) {
        self.consentStore = consentStore
        self.bundle = bundle
        self.processEnvironment = processEnvironment
        self.now = now
        self.backendFactory = backendFactory
        self.queue = DispatchQueue(
            label: "com.chiboard.telemetry",
            qos: .utility
        )
        consentObserver = DistributedNotificationCenter.default().addObserver(
            forName: TelemetryConsentStore.changedNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            self?.queue.async { self?.reconcileConsentLocked() }
        }
    }

    deinit {
        if let consentObserver {
            DistributedNotificationCenter.default().removeObserver(consentObserver)
        }
        timer?.cancel()
    }

    /// Returns immediately. SDK initialization and all disk/network work run on
    /// the utility queue, never on an input or UI event path.
    public func start(role: TelemetryProcessRole) {
        queue.async { [weak self] in
            guard let self else { return }
            self.role = role
            self.reconcileConsentLocked()
        }
    }

    public func setConsent(_ state: TelemetryConsentState) {
        queue.async { [weak self] in
            guard let self else { return }
            if state != .enabled { self.stopBackendLocked(discarding: true) }
            self.consentStore.setState(state)
            if state == .enabled {
                self.reconcileConsentLocked()
            } else {
                self.counters = TelemetryUsageSummary()
                self.windowStartedAt = nil
                self.consentStore.purgeAllCaches()
                TelemetrySigningKeyStore.delete()
            }
        }
    }

    public func record(_ event: TelemetryEvent) {
        queue.async { [weak self] in
            guard let self,
                  self.consentStore.state.permitsCollection else { return }
            switch event {
            case let .usage(counter, count):
                self.counters.increment(counter, by: count)
            case let .modelLoadResult(success, backend, milliseconds, errorCode):
                self.reportLocked(.modelLoadResult(
                    success: success,
                    backend: backend,
                    loadMilliseconds: milliseconds,
                    errorCode: errorCode
                ))
            case let .setupMilestone(milestone, result):
                self.reportLocked(.setupMilestone(milestone, result: result))
            case let .termSummary(summary):
                self.reportLocked(.termSummary(summary))
            }
        }
    }

    public func flush() {
        queue.async { [weak self] in self?.flushLocked() }
    }

    @discardableResult
    public func stop(timeout: TimeInterval) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        queue.async { [weak self] in
            self?.flushLocked()
            self?.stopBackendLocked()
            semaphore.signal()
        }
        return semaphore.wait(timeout: .now() + max(0, timeout)) == .success
    }

    private func reconcileConsentLocked() {
        guard consentStore.state == .enabled else {
            stopBackendLocked(discarding: true)
            counters = TelemetryUsageSummary()
            windowStartedAt = nil
            consentStore.purgeAllCaches()
            TelemetrySigningKeyStore.delete()
            return
        }
        guard backend == nil,
              let role,
              let identifier = consentStore.installationIDCreatingIfNeeded(),
              let runtime = TelemetryRuntimeConfiguration.load(
                  bundle: bundle,
                  processEnvironment: processEnvironment
              ) else { return }

        let context = TelemetryRecordContext(
            role: role,
            bundle: bundle,
            environment: runtime.environment
        )
        let candidate = backendFactory()
        let started = candidate.start(configuration: .init(
            collectorURL: runtime.collectorURL,
            installationID: identifier,
            role: role,
            release: context.release,
            environment: runtime.environment,
            cacheURL: consentStore.cacheURL(for: role)
        ))
        guard started else { return }
        self.context = context
        backend = candidate
        let crashCapture = TelemetryCrashCapture()
        if let crash = crashCapture.start(
            cacheURL: consentStore.cacheURL(for: role),
            context: context
        ) {
            candidate.report(crash)
            candidate.flush()
        }
        self.crashCapture = crashCapture
        counters = TelemetryUsageSummary()
        windowStartedAt = now()
        startTimerLocked()
    }

    private func startTimerLocked() {
        timer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + Self.aggregationInterval,
            repeating: Self.aggregationInterval,
            leeway: .seconds(15)
        )
        timer.setEventHandler { [weak self] in self?.flushLocked() }
        self.timer = timer
        timer.resume()
    }

    private func flushLocked() {
        guard backend != nil, let startedAt = windowStartedAt else { return }
        let endedAt = now()
        counters.windowSeconds = max(1, Int(endedAt.timeIntervalSince(startedAt)))
        if !counters.isEmpty { reportLocked(.usageSummary(counters)) }
        backend?.flush()
        counters = TelemetryUsageSummary()
        windowStartedAt = endedAt
    }

    private func reportLocked(_ event: TelemetryUploadEvent) {
        guard let backend, let context else { return }
        backend.report(TelemetryRecordFactory.make(event: event, context: context))
    }

    /// Without consent, nothing more is sent: not even what was queued.
    private func stopBackendLocked(discarding: Bool = false) {
        timer?.cancel()
        timer = nil
        crashCapture?.purge()
        crashCapture = nil
        if discarding { backend?.discard() } else { backend?.stop() }
        backend = nil
        context = nil
    }
}
