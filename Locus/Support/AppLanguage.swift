import Foundation

/// In-app language, Mongolian by default. SwiftUI text follows `.environment(\.locale)`,
/// strings built in code use `Bundle.appLanguage`, and `AppleLanguages` covers
/// system-drawn text (permission prompts) from the next launch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case mn
    case en

    static let defaultsKey = "locus.appLanguage"

    var id: String { rawValue }

    /// Shown untranslated so either language can find its way back.
    var name: String {
        switch self {
        case .mn: return "Монгол"
        case .en: return "English"
        }
    }

    static var current: AppLanguage {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(AppLanguage.init(rawValue:)) ?? .mn
    }

    static func apply(_ language: AppLanguage) {
        UserDefaults.standard.set([language.rawValue], forKey: "AppleLanguages")
    }
}

extension Bundle {
    /// The `.lproj` for the in-app language; use with `String(localized:bundle:)`.
    static var appLanguage: Bundle {
        guard let path = Bundle.main.path(forResource: AppLanguage.current.rawValue, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return .main }
        return bundle
    }
}
