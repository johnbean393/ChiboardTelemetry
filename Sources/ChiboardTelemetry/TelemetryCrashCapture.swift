import CrashReporter
import CryptoKit
import Foundation

final class TelemetryCrashCapture {
    private static let appImages = Set([
        "Chiboard", "Chiboard Setup", "Chiboard Shortcuts",
    ])

    private var reporter: PLCrashReporter?

    func start(cacheURL: URL, context: TelemetryRecordContext) -> TelemetryRecord? {
        let crashURL = cacheURL.appendingPathComponent("Crash", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: crashURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let config = PLCrashReporterConfig(basePath: crashURL.path)
        guard let reporter = PLCrashReporter(configuration: config) else { return nil }
        self.reporter = reporter

        var sanitized: TelemetryRecord?
        if reporter.hasPendingCrashReport(),
           let data = try? reporter.loadPendingCrashReportDataAndReturnError(),
           let report = try? PLCrashReport(data: data) {
            sanitized = makeRecord(report: report, context: context)
        }
        _ = try? reporter.purgePendingCrashReportAndReturnError()
        _ = try? reporter.enableAndReturnError()
        return sanitized
    }

    func purge() {
        _ = try? reporter?.purgePendingCrashReportAndReturnError()
        reporter = nil
    }

    private func makeRecord(
        report: PLCrashReport,
        context: TelemetryRecordContext
    ) -> TelemetryRecord? {
        guard let thread = (report.threads as? [PLCrashReportThreadInfo])?.first(where: { $0.crashed }) else {
            return nil
        }
        let stack = (thread.stackFrames as? [PLCrashReportStackFrameInfo] ?? []).prefix(64)
        var signatureMaterial = ""
        let frames: [[String: Any]] = stack.compactMap { frame in
            guard let image = report.image(forAddress: frame.instructionPointer),
                  image.hasImageUUID,
                  frame.instructionPointer >= image.imageBaseAddress else { return nil }
            let imageName = URL(fileURLWithPath: image.imageName).lastPathComponent
            let kind = Self.appImages.contains(imageName) ? "app" : "system"
            let uuid = image.imageUUID.lowercased()
            let offset = frame.instructionPointer - image.imageBaseAddress
            if signatureMaterial.split(separator: "|").count < 5 {
                signatureMaterial += "\(uuid):\(offset)|"
            }
            return ["image_kind": kind, "image_uuid": uuid, "image_offset": offset]
        }
        guard !frames.isEmpty,
              let frameData = try? JSONSerialization.data(withJSONObject: frames, options: [.sortedKeys]),
              let frameJSON = String(data: frameData, encoding: .utf8) else { return nil }
        let signature = SHA256.hash(data: Data(signatureMaterial.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let common = [
            TelemetryField(key: .schemaVersion, value: "1"),
            .init(key: .processRole, value: context.role.rawValue),
            .init(key: .release, value: context.release),
            .init(key: .macOSVersion, value: context.macOSVersion),
            .init(key: .environment, value: context.environment.rawValue),
        ]
        return TelemetryRecord(name: .crash, fields: common + [
            .init(key: .crashID, value: UUID().uuidString.lowercased()),
            .init(key: .signalName, value: safeToken(report.signalInfo.name)),
            .init(key: .signalCode, value: safeToken(report.signalInfo.code)),
            .init(key: .rawSignature, value: signature),
            .init(key: .frameCount, value: String(frames.count)),
            .init(key: .frames, value: frameJSON),
        ])
    }

    private func safeToken(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-")
        guard !value.isEmpty, value.count <= 40,
              value.unicodeScalars.allSatisfy(allowed.contains) else { return "unknown" }
        return value
    }
}
