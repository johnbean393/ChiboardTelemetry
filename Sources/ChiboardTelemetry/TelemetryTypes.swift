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

/// One numeric field of the daily special-term summary. Each describes the
/// user's special-term store or its activity as a count, a bucket count, or
/// a bucket's lower bound; none carries a term, key, example, or anything
/// derived from their text.
public enum TelemetryTermMetric: String, CaseIterable, Sendable {
    case termsManualChinese = "terms_manual_chinese"
    case termsManualEnglish = "terms_manual_english"
    case termsSetupChinese = "terms_setup_chinese"
    case termsSetupEnglish = "terms_setup_english"
    case termsLearnedChinese = "terms_learned_chinese"
    case termsLearnedEnglish = "terms_learned_english"
    case suggestionsPending = "suggestions_pending"
    case suggestionsAccepted = "suggestions_accepted"
    case suggestionsDismissed = "suggestions_dismissed"
    case termLength1 = "term_length_1"
    case termLength2 = "term_length_2"
    case termLength3 = "term_length_3"
    case termLength4 = "term_length_4"
    case termLength5To6 = "term_length_5_6"
    case termLength7To10 = "term_length_7_10"
    case termLength11Plus = "term_length_11_plus"
    case termSyllables1 = "term_syllables_1"
    case termSyllables2 = "term_syllables_2"
    case termSyllables3 = "term_syllables_3"
    case termSyllables4 = "term_syllables_4"
    case termSyllables5To6 = "term_syllables_5_6"
    case termSyllables7Plus = "term_syllables_7_plus"
    case keyFormFullPinyin = "key_form_full_pinyin"
    case keyFormInitials = "key_form_initials"
    case keyFormMixed = "key_form_mixed"
    case keyFormOther = "key_form_other"
    case keyFormUnknown = "key_form_unknown"
    case examplesPerTerm0 = "examples_per_term_0"
    case examplesPerTerm1 = "examples_per_term_1"
    case examplesPerTerm2 = "examples_per_term_2"
    case examplesPerTerm3 = "examples_per_term_3"
    case examplesPerTerm4Plus = "examples_per_term_4_plus"
    case exampleLength1To10 = "example_length_1_10"
    case exampleLength11To20 = "example_length_11_20"
    case exampleLength21To40 = "example_length_21_40"
    case exampleLength41To80 = "example_length_41_80"
    case exampleLength81Plus = "example_length_81_plus"
    case snapshotEntries = "snapshot_entries"
    case snapshotTokensBucket = "snapshot_tokens_bucket"
    case correctionsCandidateChoice = "corrections_candidate_choice"
    case correctionsReconversion = "corrections_reconversion"
    case correctionsReconstructedReconversion = "corrections_reconstructed_reconversion"
    case correctionsRetype = "corrections_retype"
    case suggestionsCreated = "suggestions_created"
    case suggestionAccepts = "suggestion_accepts"
    case suggestionDismissals = "suggestion_dismissals"
    case manualAdds = "manual_adds"
    case termEdits = "term_edits"
    case termDeletes = "term_deletes"
    case deleteAgeUnder1Day = "delete_age_under_1d"
    case deleteAge1To7Days = "delete_age_1_7d"
    case deleteAge8To30Days = "delete_age_8_30d"
    case deleteAge31To90Days = "delete_age_31_90d"
    case deleteAge91DaysPlus = "delete_age_91d_plus"
    case fireKeyMatches = "fire_key_matches"
    case fireAlreadyCorrect = "fire_already_correct"
    case fireMissed = "fire_missed"
    case fireAppliedKept = "fire_applied_kept"
    case fireOfferedKept = "fire_offered_kept"
    case fireOverridden = "fire_overridden"
    case snapshotBuilds = "snapshot_builds"
    case snapshotChanges = "snapshot_changes"
}

/// One local day of special-term statistics: counts only. Values are
/// clamped to what the collector accepts: 0...Int32.max, at most the
/// snapshot's 64 entries, and a token bucket's lower bound.
public struct TelemetryTermSummary: Equatable, Sendable {
    public static let snapshotCapacity: Int64 = 64
    public static let snapshotTokenBuckets: [Int64] = [0, 1, 256, 512, 1024, 2048, 4096, 8192]

    public private(set) var values: [TelemetryTermMetric: Int64]

    public init(_ values: [TelemetryTermMetric: Int64] = [:]) {
        var clamped = values.mapValues { min(max(0, $0), Int64(Int32.max)) }
        if let entries = clamped[.snapshotEntries] { clamped[.snapshotEntries] = min(entries, Self.snapshotCapacity) }
        if let tokens = clamped[.snapshotTokensBucket] {
            clamped[.snapshotTokensBucket] = Self.snapshotTokenBuckets.last { $0 <= tokens } ?? 0
        }
        self.values = clamped
    }

    public subscript(metric: TelemetryTermMetric) -> Int64 {
        values[metric] ?? 0
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
    /// A finished local day's special-term statistics, sent as one record.
    case termSummary(TelemetryTermSummary)
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
