import SwiftUI

// 화면 테마 — .system이면 OS 설정 따름(AppColor가 이미 trait 대응).
enum ThemeMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
    var label: LocalizedStringKey {
        switch self {
        case .system: "시스템"
        case .light: "라이트"
        case .dark: "다크"
        }
    }
}

// 앱 언어 — .system이면 기기 언어 따름.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, ko, en
    var id: String { rawValue }
    var locale: Locale {
        switch self {
        case .system: .autoupdatingCurrent
        case .ko: Locale(identifier: "ko")
        case .en: Locale(identifier: "en")
        }
    }
    var label: LocalizedStringKey {
        switch self {
        case .system: "시스템"
        case .ko: "한국어"
        case .en: "English"
        }
    }
}

// 앱 전역 설정(테마·언어). UserDefaults 영속. 앱 루트에서 override 적용.
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()

    var themeMode: ThemeMode {
        didSet { defaults.set(themeMode.rawValue, forKey: Keys.theme) }
    }
    var appLanguage: AppLanguage {
        didSet { defaults.set(appLanguage.rawValue, forKey: Keys.lang) }
    }

    private let defaults = UserDefaults.standard
    private enum Keys {
        static let theme = "settings.themeMode"
        static let lang = "settings.appLanguage"
    }

    private init() {
        themeMode = ThemeMode(rawValue: defaults.string(forKey: Keys.theme) ?? "") ?? .system
        appLanguage = AppLanguage(rawValue: defaults.string(forKey: Keys.lang) ?? "") ?? .system
    }
}
