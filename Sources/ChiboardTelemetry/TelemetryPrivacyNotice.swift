import Foundation

public enum TelemetryPrivacyNoticeLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case simplifiedChinese = "zh-Hans"
}

public enum TelemetryPrivacyNotice {
    static var privacyManifestURL: URL? {
        Bundle.module.url(forResource: "PrivacyInfo", withExtension: "xcprivacy")
    }

    public static func text(language: TelemetryPrivacyNoticeLanguage) -> String {
        guard let url = Bundle.module.url(
            forResource: "PrivacyNotice",
            withExtension: "txt",
            subdirectory: nil,
            localization: language.rawValue
        ), let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "Privacy notice unavailable. Contact johnbean393@gmail.com."
        }
        return text
    }
}
