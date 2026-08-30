import Foundation

public enum TelemetryConsentState: String, Codable, CaseIterable, Sendable {
    case unset
    case disabled
    case enabled

    public var permitsCollection: Bool { self == .enabled }
}

public enum TelemetryProcessRole: String, Codable, CaseIterable, Sendable {
    case inputMethod = "input_method"
    case setup
    case shortcuts
}

public enum TelemetryEnvironment: String, Codable, CaseIterable, Sendable {
    case production = "prod"
    case test
}

public enum TelemetryUsageCounter: String, Codable, CaseIterable, Sendable {
    case conversionsStarted = "conversions_started"
    case conversionsApplied = "conversions_applied"
    case conversionsFailed = "conversions_failed"
    case conversionsRejected = "conversions_rejected"
    case conversionsStale = "conversions_stale"
    case candidateRequests = "candidate_requests"
    case candidateApplies = "candidate_applies"
    case shortcutAttempts = "shortcut_attempts"
    case shortcutSuccesses = "shortcut_successes"
}

public enum TelemetryModelBackend: String, Codable, CaseIterable, Sendable {
    case metal
    case cpu
    case none
}

/// Stable, allowlisted failure categories. Native error codes are deliberately
/// not accepted by the telemetry API because they are not a durable contract.
public enum TelemetryModelLoadErrorCode: Int, Codable, CaseIterable, Sendable {
    case none = 0
    case modelMissing = 1
    case invalidConfiguration = 2
    case engineLoadFailed = 3
}

public enum TelemetrySetupMilestone: String, Codable, CaseIterable, Sendable {
    case privacyPreferenceSaved = "privacy_preference_saved"
    case modelReady = "model_ready"
    case benchmarkComplete = "benchmark_complete"
    case restartComplete = "restart_complete"
    case inputSourceEnabled = "input_source_enabled"
    case shortcutsComplete = "shortcuts_complete"
    case specialTermsComplete = "special_terms_complete"
    case tutorialComplete = "tutorial_complete"
}

public enum TelemetrySetupResult: String, Codable, CaseIterable, Sendable {
    case success
    case skipped
    case failed
}

public struct TelemetryUsageSummary: Equatable, Sendable {
    public var windowSeconds: Int
    public var conversionsStarted: Int64
    public var conversionsApplied: Int64
    public var conversionsFailed: Int64
    public var conversionsRejected: Int64
    public var conversionsStale: Int64
    public var candidateRequests: Int64
    public var candidateApplies: Int64
    public var shortcutAttempts: Int64
    public var shortcutSuccesses: Int64

    public init(
        windowSeconds: Int = 0,
        conversionsStarted: Int64 = 0,
        conversionsApplied: Int64 = 0,
        conversionsFailed: Int64 = 0,
        conversionsRejected: Int64 = 0,
        conversionsStale: Int64 = 0,
        candidateRequests: Int64 = 0,
        candidateApplies: Int64 = 0,
        shortcutAttempts: Int64 = 0,
        shortcutSuccesses: Int64 = 0
    ) {
        self.windowSeconds = max(0, windowSeconds)
        self.conversionsStarted = max(0, conversionsStarted)
        self.conversionsApplied = max(0, conversionsApplied)
        self.conversionsFailed = max(0, conversionsFailed)
        self.conversionsRejected = max(0, conversionsRejected)
        self.conversionsStale = max(0, conversionsStale)
        self.candidateRequests = max(0, candidateRequests)
        self.candidateApplies = max(0, candidateApplies)
        self.shortcutAttempts = max(0, shortcutAttempts)
        self.shortcutSuccesses = max(0, shortcutSuccesses)
    }

    /// Cancellations and stale responses are intentionally absent from the
    /// denominator, matching the published metric definition.
    public var conversionSuccessRate: Double? {
        let completed = conversionsApplied + conversionsFailed + conversionsRejected
        guard completed > 0 else { return nil }
        return Double(conversionsApplied) / Double(completed)
    }

    public var isEmpty: Bool {
        conversionsStarted == 0 && conversionsApplied == 0 &&
            conversionsFailed == 0 && conversionsRejected == 0 &&
            conversionsStale == 0 && candidateRequests == 0 &&
            candidateApplies == 0 && shortcutAttempts == 0 &&
            shortcutSuccesses == 0
    }

    mutating func increment(_ counter: TelemetryUsageCounter, by count: Int64) {
        guard count > 0 else { return }
        switch counter {
        case .conversionsStarted: conversionsStarted += count
        case .conversionsApplied: conversionsApplied += count
        case .conversionsFailed: conversionsFailed += count
        case .conversionsRejected: conversionsRejected += count
        case .conversionsStale: conversionsStale += count
        case .candidateRequests: candidateRequests += count
        case .candidateApplies: candidateApplies += count
        case .shortcutAttempts: shortcutAttempts += count
        case .shortcutSuccesses: shortcutSuccesses += count
        }
    }
}

/// The only recordable events. There is intentionally no arbitrary event,
/// property, dictionary, log, snapshot, or manual crash case.
public enum TelemetryEvent: Equatable, Sendable {
    case usage(TelemetryUsageCounter, count: Int64 = 1)
    case modelLoadResult(
        success: Bool,
        backend: TelemetryModelBackend,
        loadMilliseconds: Int,
        errorCode: TelemetryModelLoadErrorCode
    )
    case setupMilestone(TelemetrySetupMilestone, result: TelemetrySetupResult)
}

public protocol TelemetryReporting: AnyObject {
    func start(role: TelemetryProcessRole)
    func record(_ event: TelemetryEvent)
    func flush()

    @discardableResult
    func stop(timeout: TimeInterval) -> Bool
}

public extension TelemetryReporting {
    @discardableResult
    func stop() -> Bool { stop(timeout: 0.5) }
}
