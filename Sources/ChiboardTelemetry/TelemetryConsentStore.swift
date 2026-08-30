import Foundation

public final class TelemetryConsentStore: @unchecked Sendable {
    public static let preferencesDomain = "com.chiboard.inputmethod.settings"
    public static let changedNotification = Notification.Name(
        "com.chiboard.inputmethod.telemetry-consent.changed"
    )

    private enum Key {
        static let consent = "telemetryConsentState"
        static let installationID = "telemetryInstallationID"
        static let noticeVersion = "telemetryPrivacyNoticeVersion"
    }

    public static let currentNoticeVersion = 1

    private let defaults: UserDefaults
    private let fileManager: FileManager
    private let cacheRootOverride: URL?
    private let lock = NSLock()

    public init(
        defaults: UserDefaults? = nil,
        fileManager: FileManager = .default,
        cacheRootURL: URL? = nil
    ) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: Self.preferencesDomain)
            ?? .standard
        self.fileManager = fileManager
        self.cacheRootOverride = cacheRootURL
    }

    public var state: TelemetryConsentState {
        lock.withLock {
            defaults.string(forKey: Key.consent)
                .flatMap(TelemetryConsentState.init(rawValue:)) ?? .unset
        }
    }

    public var installationID: UUID? {
        lock.withLock {
            guard storedStateLocked() == .enabled,
                  let value = defaults.string(forKey: Key.installationID) else {
                return nil
            }
            return UUID(uuidString: value)
        }
    }

    /// Repairs a missing identifier only when collection is already enabled.
    /// Merely reading consent while it is unset or disabled never creates one.
    public func installationIDCreatingIfNeeded() -> UUID? {
        lock.withLock {
            guard storedStateLocked() == .enabled else { return nil }
            if let value = defaults.string(forKey: Key.installationID),
               let identifier = UUID(uuidString: value) {
                return identifier
            }
            let identifier = UUID()
            defaults.set(identifier.uuidString.lowercased(), forKey: Key.installationID)
            defaults.synchronize()
            return identifier
        }
    }

    public var privacyNoticeVersion: Int? {
        lock.withLock {
            guard defaults.object(forKey: Key.noticeVersion) != nil else { return nil }
            return defaults.integer(forKey: Key.noticeVersion)
        }
    }

    /// Enabling creates the pseudonymous identifier. Disabling or returning to
    /// unset destroys it immediately; callers should use TelemetryClient's
    /// consent method so a live SDK is stopped before its caches are purged.
    @discardableResult
    public func setState(_ newState: TelemetryConsentState) -> UUID? {
        let identifier = lock.withLock { () -> UUID? in
            switch newState {
            case .unset:
                defaults.removeObject(forKey: Key.consent)
                defaults.removeObject(forKey: Key.installationID)
                defaults.removeObject(forKey: Key.noticeVersion)
                defaults.synchronize()
                return nil
            case .disabled:
                defaults.set(newState.rawValue, forKey: Key.consent)
                defaults.removeObject(forKey: Key.installationID)
                defaults.set(Self.currentNoticeVersion, forKey: Key.noticeVersion)
                defaults.synchronize()
                return nil
            case .enabled:
                let identifier = defaults.string(forKey: Key.installationID)
                    .flatMap(UUID.init(uuidString:)) ?? UUID()
                defaults.set(newState.rawValue, forKey: Key.consent)
                defaults.set(identifier.uuidString.lowercased(), forKey: Key.installationID)
                defaults.set(Self.currentNoticeVersion, forKey: Key.noticeVersion)
                defaults.synchronize()
                return identifier
            }
        }
        broadcastChange()
        return identifier
    }

    public func disableAndResetIdentifier() {
        setState(.disabled)
    }

    public func cacheURL(for role: TelemetryProcessRole) -> URL {
        telemetryCacheRoot.appendingPathComponent(role.rawValue, isDirectory: true)
    }

    public func purgeAllCaches() {
        let root = telemetryCacheRoot
        guard fileManager.fileExists(atPath: root.path) else { return }
        try? fileManager.removeItem(at: root)
    }

    public var telemetryCacheRoot: URL {
        if let cacheRootOverride { return cacheRootOverride }
        let caches = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return caches
            .appendingPathComponent("Chiboard", isDirectory: true)
            .appendingPathComponent("Telemetry", isDirectory: true)
    }

    private func storedStateLocked() -> TelemetryConsentState {
        defaults.string(forKey: Key.consent)
            .flatMap(TelemetryConsentState.init(rawValue:)) ?? .unset
    }

    private func broadcastChange() {
        DistributedNotificationCenter.default().postNotificationName(
            Self.changedNotification,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
        NotificationCenter.default.post(name: Self.changedNotification, object: self)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
