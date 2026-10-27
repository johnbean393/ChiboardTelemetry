import CryptoKit
import Foundation
import Security

struct TelemetryBackendConfiguration: Equatable {
    let collectorURL: URL
    let installationID: UUID
    let role: TelemetryProcessRole
    let release: String
    let environment: TelemetryEnvironment
    let cacheURL: URL
}

protocol TelemetryBackend: AnyObject {
    func start(configuration: TelemetryBackendConfiguration) -> Bool
    func report(_ record: TelemetryRecord)
    func flush()
    /// Stops sending. Shutdown flushes first; this sends nothing itself.
    func stop()
    /// Consent was withdrawn: stops, and cancels requests already started.
    func discard()
}

final class NoOpTelemetryBackend: TelemetryBackend {
    func start(configuration: TelemetryBackendConfiguration) -> Bool { false }
    func report(_ record: TelemetryRecord) {}
    func flush() {}
    func stop() {}
    func discard() {}
}

enum TelemetrySigningKeyStore {
    private static let service = "com.chiboard.inputmethod.telemetry"
    private static let account = "installation-signing-key-v1"

    static func loadOrCreate() throws -> Curve25519.Signing.PrivateKey {
        let query = baseQuery.merging([
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]) { _, new in new }
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data {
            return try Curve25519.Signing.PrivateKey(rawRepresentation: data)
        }
        guard status == errSecItemNotFound else { throw KeychainError(status) }

        let key = Curve25519.Signing.PrivateKey()
        let add = baseQuery.merging([
            kSecValueData as String: key.rawRepresentation,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]) { _, new in new }
        let addStatus = SecItemAdd(add as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(addStatus) }
        return key
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    private static var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private struct KeychainError: Error {
        let status: OSStatus
        init(_ status: OSStatus) { self.status = status }
    }
}

struct TelemetrySignedBatch {
    static let schemaVersion = 1

    let body: Data
    let signature: String
    let batchID: UUID

    init(
        records: [TelemetryRecord],
        installationID: UUID,
        key: Curve25519.Signing.PrivateKey,
        now: Date = Date(),
        batchID: UUID = UUID()
    ) throws {
        guard !records.isEmpty, records.count <= 50 else { throw EncodingError.invalidCount }
        let publicKey = key.publicKey.rawRepresentation
        let keyID = SHA256.hash(data: publicKey).map { String(format: "%02x", $0) }.joined()
        let events: [[String: String]] = records.map { record in
            var event = Dictionary(uniqueKeysWithValues: record.fields.map {
                ($0.name, $0.value)
            })
            event["event"] = record.name.rawValue
            return event
        }
        let object: [String: Any] = [
            "schema_version": Self.schemaVersion,
            "batch_id": batchID.uuidString.lowercased(),
            "sent_at": Int(now.timeIntervalSince1970),
            "installation_id": installationID.uuidString.lowercased(),
            "key_id": keyID,
            "public_key": Self.base64URL(publicKey),
            "events": events,
        ]
        body = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        signature = Self.base64URL(try key.signature(for: body))
        self.batchID = batchID
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private enum EncodingError: Error { case invalidCount }
}

/// Privacy-preserving first-party transport. It writes a signed batch to the
/// process-specific queue before attempting a request, and removes it only
/// after the collector acknowledges it. No Alibaba credential enters the app.
final class CollectorTelemetryBackend: TelemetryBackend, @unchecked Sendable {
    private let fileManager: FileManager
    private let session: URLSession
    private let lock = NSLock()
    private var configuration: TelemetryBackendConfiguration?
    private var signingKey: Curve25519.Signing.PrivateKey?
    private var uploads: Set<URL> = []
    private var requests: [URL: URLSessionDataTask] = [:]
    private var running = false

    init(fileManager: FileManager = .default, session: URLSession = .shared) {
        self.fileManager = fileManager
        self.session = session
    }

    func start(configuration: TelemetryBackendConfiguration) -> Bool {
        guard configuration.collectorURL.scheme?.lowercased() == "https",
              configuration.collectorURL.user == nil,
              configuration.collectorURL.password == nil,
              configuration.collectorURL.fragment == nil else { return false }
        do {
            try fileManager.createDirectory(
                at: queueURL(configuration),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let key = try TelemetrySigningKeyStore.loadOrCreate()
            lock.withLock {
                self.configuration = configuration
                signingKey = key
                running = true
            }
            pruneQueue(configuration: configuration)
            flush()
            return true
        } catch {
            return false
        }
    }

    func report(_ record: TelemetryRecord) {
        guard let state = lock.withLock({ () -> (TelemetryBackendConfiguration, Curve25519.Signing.PrivateKey)? in
            guard running, let configuration, let signingKey else { return nil }
            return (configuration, signingKey)
        }) else { return }
        do {
            let batch = try TelemetrySignedBatch(
                records: [record],
                installationID: state.0.installationID,
                key: state.1
            )
            let envelope: [String: String] = [
                "signature": batch.signature,
                "body": batch.body.base64EncodedString(),
            ]
            let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
            let file = queueURL(state.0)
                .appendingPathComponent(batch.batchID.uuidString.lowercased())
                .appendingPathExtension("json")
            try data.write(to: file, options: .atomic)
            try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            return
        }
    }

    func flush() {
        guard let configuration = lock.withLock({ running ? self.configuration : nil }) else { return }
        let files = (try? fileManager.contentsOfDirectory(
            at: queueURL(configuration),
            includingPropertiesForKeys: [.creationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ))?.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        for file in files.prefix(3) { upload(file, configuration: configuration) }
    }

    func stop() {
        lock.withLock {
            running = false
            configuration = nil
            signingKey = nil
        }
    }

    func discard() {
        stop()
        let started = lock.withLock { () -> [URLSessionDataTask] in
            defer { requests = [:] }
            return Array(requests.values)
        }
        started.forEach { $0.cancel() }
    }

    private func upload(_ file: URL, configuration: TelemetryBackendConfiguration) {
        let shouldStart = lock.withLock { () -> Bool in
            guard running, !uploads.contains(file) else { return false }
            uploads.insert(file)
            return true
        }
        guard shouldStart,
              let data = try? Data(contentsOf: file),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              let signature = envelope["signature"],
              let encodedBody = envelope["body"],
              let body = Data(base64Encoded: encodedBody) else {
            _ = lock.withLock { uploads.remove(file) }
            try? fileManager.removeItem(at: file)
            return
        }

        var request = URLRequest(url: configuration.collectorURL)
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(signature, forHTTPHeaderField: "X-Chiboard-Signature")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        let task = session.dataTask(with: request) { [weak self] _, response, _ in
            guard let self else { return }
            let accepted = (response as? HTTPURLResponse).map { 200..<300 ~= $0.statusCode } ?? false
            if accepted { try? self.fileManager.removeItem(at: file) }
            self.lock.withLock {
                _ = self.uploads.remove(file)
                self.requests[file] = nil
            }
            if accepted { self.flush() }
        }
        // Consent may have been withdrawn while the request was prepared:
        // `discard()` cancels only requests registered before it ran.
        let registered = lock.withLock { () -> Bool in
            guard running else {
                uploads.remove(file)
                return false
            }
            requests[file] = task
            return true
        }
        if registered { task.resume() }
    }

    private func queueURL(_ configuration: TelemetryBackendConfiguration) -> URL {
        configuration.cacheURL.appendingPathComponent("Queue", isDirectory: true)
    }

    private func pruneQueue(configuration: TelemetryBackendConfiguration) {
        let queue = queueURL(configuration)
        let files = (try? fileManager.contentsOfDirectory(
            at: queue,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let cutoff = Date().addingTimeInterval(-7 * 24 * 60 * 60)
        let sorted = files.sorted { $0.lastPathComponent < $1.lastPathComponent }
        for (index, file) in sorted.enumerated() {
            let created = try? file.resourceValues(forKeys: [.creationDateKey]).creationDate
            if index < max(0, sorted.count - 500) || (created.map { $0 < cutoff } ?? false) {
                try? fileManager.removeItem(at: file)
            }
        }
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
