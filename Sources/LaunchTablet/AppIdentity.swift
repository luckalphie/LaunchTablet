import Foundation

enum AppIdentity {
    static let name = "LaunchTablet"
    static let bundleIdentifier = "com.local.launchtablet"
    static let secondaryBundleIdentifier = "com.local.launchtablet.secondary-test"
    static let legacyBundleIdentifier = "com.local.launchpad"
    static let legacySecondaryBundleIdentifier = "com.local.launchpad.secondary-test"
    static let legacyDataDirectory = "Launchpad"

    static func isLauncher(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return [self.bundleIdentifier, secondaryBundleIdentifier, legacyBundleIdentifier, legacySecondaryBundleIdentifier].contains(bundleIdentifier)
    }

    /// 只迁移本项目已有的设置键，且不覆盖新版偏好；不复制 AppleLanguages 等系统设置。
    static func migrateLegacyPreferences(to preferences: UserDefaults, legacyValues: [String: Any]) {
        for key in ["shortcut", "interfaceLanguage"] where preferences.object(forKey: key) == nil {
            if let value = legacyValues[key] as? String { preferences.set(value, forKey: key) }
        }
    }
}
