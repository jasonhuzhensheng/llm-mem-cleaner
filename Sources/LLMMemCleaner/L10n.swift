import Foundation

enum Language: String, CaseIterable, Identifiable {
    case zh, en
    var id: String { rawValue }
    var label: String { self == .zh ? "中文" : "English" }
}

enum L10n {
    static let defaultsKey = "language"

    /// Saved choice, else the system's preferred language.
    static var current: Language = {
        if let saved = UserDefaults.standard.string(forKey: defaultsKey), let lang = Language(rawValue: saved) {
            return lang
        }
        return Locale.preferredLanguages.first?.hasPrefix("zh") == true ? .zh : .en
    }()
}

/// Picks the string for the current UI language; both versions sit side by side at the call site.
func tr(_ zh: String, _ en: String) -> String {
    L10n.current == .zh ? zh : en
}
