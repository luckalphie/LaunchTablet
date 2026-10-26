import Foundation

private final class LocalizationBundleAnchor {}

enum InterfaceLanguage: String, CaseIterable, Identifiable {
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    /// 按用户语言优先级选择首个支持的语言；其它语言回退英文，中文地区变体使用简体中文。
    func resolved(preferredLanguages: [String]) -> InterfaceLanguage {
        guard self == .system else { return self }
        for language in preferredLanguages {
            let code = language.lowercased().replacingOccurrences(of: "_", with: "-")
            if code == "zh" || code.hasPrefix("zh-") { return .simplifiedChinese }
            if code == "en" || code.hasPrefix("en-") { return .english }
        }
        return .english
    }
}

/// 类似 Java 的资源键枚举 + ResourceBundle；文案保存在标准 .lproj/Localizable.strings 中。
enum TextKey: String, CaseIterable {
    case search, clearSearch, noApplications, noResults, restoreHiddenHint, searchHint
    case operationFailed, okay, keyboardControls, helpTitle, helpBody, settings
    case openFolder, renameFolder, dissolveFolder, openApplication, revealInFinder, moveOutOfFolder, newFolder, hideApplication
    case pageDescription, currentPage, previousPage, nextPage, folderName, closeFolder, folder, application
    case settingsTitle, displayDescription, shortcutTitle, languageTitle, systemLanguage
    case gridAreaTitle, gridAreaFullScreen, gridArea14, gridArea16, gridArea24, gridArea27
    case refreshApplications, manualArrangement, defaultArrangement, resetArrangement, resetConfirmation, resetButton, cancel, resetExplanation
    case hiddenApplications, noHiddenApplications, restoreApplication, organizationHelp, quitApplication
    case shortcutDisabled, spaceKey, invalidLayout, inaccessibleApplications, launchFailed, saveFailed, shortcutUnavailable
    case aboutApplication, toggleApplication, menuSettings, editMenu, undo, cut, copy, paste, selectAll
    case utilitiesCategory, gamesCategory, otherCategory, secondaryTestName
}

struct Localizer {
    var language: InterfaceLanguage
    var preferredLanguages: [String] = Locale.preferredLanguages

    var resolvedLanguage: InterfaceLanguage { language.resolved(preferredLanguages: preferredLanguages) }
    var locale: Locale { Locale(identifier: resolvedLanguage.rawValue) }

    /// 显式查找随包资源，不把开发机器的绝对构建路径编入 Release。
    /// SwiftPM 调试构建使用生成的访问器；分发包和离屏预览从可执行文件附近查找资源。
    static let resources: Bundle = {
        #if SWIFT_PACKAGE && DEBUG
        // SwiftPM 测试由工具链宿主动态加载，Bundle.main 未必是本模块。
        // 调试构建使用生成的资源访问器；Release 不引用它，避免嵌入本机绝对构建路径。
        return .module
        #else
        let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent()
        let candidates = [Bundle.main.resourceURL,
                          Bundle(for: LocalizationBundleAnchor.self).resourceURL?.appendingPathComponent("LaunchTablet_LaunchTablet.bundle"),
                          Bundle.main.resourceURL?.appendingPathComponent("LaunchTablet_LaunchTablet.bundle"),
                          executableDirectory?.appendingPathComponent("LaunchTablet_LaunchTablet.bundle"),
                          Bundle.main.bundleURL.appendingPathComponent("LaunchTablet_LaunchTablet.bundle"),
                          executableDirectory?.appendingPathComponent("Resources")]
        for case let url? in candidates {
            if let bundle = Bundle(url: url), bundle.url(forResource: "en", withExtension: "lproj") != nil { return bundle }
        }
        return .main
        #endif
    }()

    static func resourceDirectory(for language: InterfaceLanguage) -> URL? {
        // 旧 SwiftPM 会把 zh-Hans.lproj 输出为 zh-hans.lproj，Bundle 查询区分这两种拼写。
        resources.url(forResource: language.rawValue, withExtension: "lproj")
            ?? resources.url(forResource: language.rawValue.lowercased(), withExtension: "lproj")
    }

    func text(_ key: TextKey, arguments: [CVarArg] = []) -> String {
        let selected = Self.resourceDirectory(for: resolvedLanguage).flatMap(Bundle.init(url:))
        let english = Self.resourceDirectory(for: .english).flatMap(Bundle.init(url:))
        let fallback = english?.localizedString(forKey: key.rawValue, value: key.rawValue, table: nil) ?? key.rawValue
        let format = selected?.localizedString(forKey: key.rawValue, value: fallback, table: nil) ?? fallback
        return arguments.isEmpty ? format : String(format: format, locale: locale, arguments: arguments)
    }
}
