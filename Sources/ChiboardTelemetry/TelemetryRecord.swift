import Foundation

enum TelemetryRecordName: String, CaseIterable {
    case usageSummary = "usage_summary"
    case modelLoadResult = "model_load_result"
    case setupMilestone = "setup_milestone"
    case crash
}

enum TelemetryFieldKey: String, CaseIterable {
    case schemaVersion = "schema_version"
    case processRole = "process_role"
    case release
    case macOSVersion = "macos_version"
    case environment
    case windowSeconds = "window_seconds"
    case conversionsStarted = "conversions_started"
    case conversionsApplied = "conversions_applied"
    case conversionsFailed = "conversions_failed"
    case conversionsRejected = "conversions_rejected"
    case conversionsStale = "conversions_stale"
    case candidateRequests = "candidate_requests"
    case candidateApplies = "candidate_applies"
    case shortcutAttempts = "shortcut_attempts"
    case shortcutSuccesses = "shortcut_successes"
    case success
    case backend
    case loadMilliseconds = "load_milliseconds"
    case errorCode = "error_code"
    case milestone
    case result
    case crashID = "crash_id"
    case signalName = "signal_name"
    case signalCode = "signal_code"
    case rawSignature = "raw_signature"
    case frameCount = "frame_count"
    case frames
}

struct TelemetryField: Equatable {
    let key: TelemetryFieldKey
    let value: String
}

struct TelemetryRecord: Equatable {
    static let schemaVersion = 1

    let name: TelemetryRecordName
    let fields: [TelemetryField]

    var canonicalJSON: String {
        var object = Dictionary(uniqueKeysWithValues: fields.map { ($0.key.rawValue, $0.value) })
        object["event"] = name.rawValue
        let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return data.flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }
}

struct TelemetryRecordContext: Equatable {
    let role: TelemetryProcessRole
    let release: String
    let macOSVersion: String
    let environment: TelemetryEnvironment

    init(
        role: TelemetryProcessRole,
        release: String,
        macOSVersion: String,
        environment: TelemetryEnvironment
    ) {
        self.role = role
        self.release = Self.sanitizedRelease(release)
        self.macOSVersion = Self.sanitizedOSVersion(macOSVersion)
        self.environment = environment
    }

    init(
        role: TelemetryProcessRole,
        bundle: Bundle,
        processInfo: ProcessInfo = .processInfo,
        environment: TelemetryEnvironment
    ) {
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "0"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let version = processInfo.operatingSystemVersion
        self.init(
            role: role,
            release: "\(shortVersion)+\(build)",
            macOSVersion: "\(version.majorVersion).\(version.minorVersion)",
            environment: environment
        )
    }

    private static func sanitizedRelease(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._+-")
        guard !value.isEmpty,
              value.count <= 64,
              value.unicodeScalars.allSatisfy(allowed.contains) else {
            return "unknown"
        }
        return value
    }

    private static func sanitizedOSVersion(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "0123456789.")
        guard !value.isEmpty,
              value.count <= 16,
              value.unicodeScalars.allSatisfy(allowed.contains) else {
            return "unknown"
        }
        return value
    }
}

enum TelemetryUploadEvent: Equatable {
    case usageSummary(TelemetryUsageSummary)
    case modelLoadResult(
        success: Bool,
        backend: TelemetryModelBackend,
        loadMilliseconds: Int,
        errorCode: TelemetryModelLoadErrorCode
    )
    case setupMilestone(TelemetrySetupMilestone, result: TelemetrySetupResult)
}

enum TelemetryRecordFactory {
    static func make(
        event: TelemetryUploadEvent,
        context: TelemetryRecordContext
    ) -> TelemetryRecord {
        let common = [
            TelemetryField(key: .schemaVersion, value: String(TelemetryRecord.schemaVersion)),
            TelemetryField(key: .processRole, value: context.role.rawValue),
            TelemetryField(key: .release, value: context.release),
            TelemetryField(key: .macOSVersion, value: context.macOSVersion),
            TelemetryField(key: .environment, value: context.environment.rawValue),
        ]
        switch event {
        case let .usageSummary(summary):
            return TelemetryRecord(name: .usageSummary, fields: common + [
                .init(key: .windowSeconds, value: String(max(0, summary.windowSeconds))),
                .init(key: .conversionsStarted, value: String(summary.conversionsStarted)),
                .init(key: .conversionsApplied, value: String(summary.conversionsApplied)),
                .init(key: .conversionsFailed, value: String(summary.conversionsFailed)),
                .init(key: .conversionsRejected, value: String(summary.conversionsRejected)),
                .init(key: .conversionsStale, value: String(summary.conversionsStale)),
                .init(key: .candidateRequests, value: String(summary.candidateRequests)),
                .init(key: .candidateApplies, value: String(summary.candidateApplies)),
                .init(key: .shortcutAttempts, value: String(summary.shortcutAttempts)),
                .init(key: .shortcutSuccesses, value: String(summary.shortcutSuccesses)),
            ])
        case let .modelLoadResult(success, backend, milliseconds, errorCode):
            return TelemetryRecord(name: .modelLoadResult, fields: common + [
                .init(key: .success, value: success ? "true" : "false"),
                .init(key: .backend, value: backend.rawValue),
                .init(key: .loadMilliseconds, value: String(max(0, milliseconds))),
                .init(key: .errorCode, value: String(errorCode.rawValue)),
            ])
        case let .setupMilestone(milestone, result):
            return TelemetryRecord(name: .setupMilestone, fields: common + [
                .init(key: .milestone, value: milestone.rawValue),
                .init(key: .result, value: result.rawValue),
            ])
        }
    }
}
