import Foundation
import Testing
@testable import LaunchTablet

@Suite final class LocalizationTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private let suiteName = "LaunchTabletLocalizationTests." + UUID().uuidString

    deinit {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    @Test func systemLanguageHonorsPriorityAndFallsBackToEnglish() {
        #expect(InterfaceLanguage.system.resolved(preferredLanguages: ["en-US", "zh-Hans"]) == .english)
        #expect(InterfaceLanguage.system.resolved(preferredLanguages: ["zh-Hant-HK", "en"]) == .simplifiedChinese)
        #expect(InterfaceLanguage.system.resolved(preferredLanguages: ["fr-FR", "zh_CN", "en"]) == .simplifiedChinese)
        #expect(InterfaceLanguage.system.resolved(preferredLanguages: ["de", "en-GB", "zh"]) == .english)
        #expect(InterfaceLanguage.system.resolved(preferredLanguages: ["ja"]) == .english)
        #expect(InterfaceLanguage.system.resolved(preferredLanguages: []) == .english)
        #expect(InterfaceLanguage.english.resolved(preferredLanguages: ["zh"]) == .english)
        #expect(InterfaceLanguage.simplifiedChinese.resolved(preferredLanguages: ["en"]) == .simplifiedChinese)
    }

    @Test func bothResourceFilesContainEveryInterfaceKey() throws {
        for language in [InterfaceLanguage.english, .simplifiedChinese] {
            let url = try #require(Localizer.resourceDirectory(for: language))
                .appendingPathComponent("Localizable.strings")
            let data = try Data(contentsOf: url)
            let strings = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String])
            #expect(Set(strings.keys) == Set(TextKey.allCases.map(\.rawValue)))
            for key in TextKey.allCases {
                let value = try #require(strings[key.rawValue])
                #expect(!value.isEmpty)
                if language == .english { #expect(value.range(of: "\\p{Han}", options: .regularExpression) == nil) }
            }
        }
    }

    @Test func translatedArgumentsAndShortcutLabelsAreFormattedCorrectly() {
        let english = Localizer(language: .english)
        let chinese = Localizer(language: .simplifiedChinese)
        #expect(english.text(.pageDescription, arguments: [2, 3]) == "Page 2 of 3")
        #expect(chinese.text(.pageDescription, arguments: [2, 3]) == "第 2 页，共 3 页")
        #expect(english.text(.hiddenApplications, arguments: [0]) == "Hidden Apps (0)")
        #expect(english.text(.launchFailed, arguments: ["App %@", "Unavailable"]) == "Could not open “App %@”: Unavailable")
        #expect(ShortcutPreset.controlOptionSpace.label(using: english) == "⌃ ⌥ Space")
        #expect(ShortcutPreset.controlOptionSpace.label(using: chinese) == "⌃ ⌥ 空格")
        #expect(ShortcutPreset.disabled.label(using: english) == "Disabled")
    }

    @MainActor
    @Test func languageSwitchPersistsAndNeverRewritesLayout() async throws {
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        let repository = LayoutRepository(fileURL: directory.appendingPathComponent("layout.json"))
        let folder = LauncherItem.categoryFolder(.utilities, applicationIDs: ["app"])
        try repository.save(LauncherLayout(items: [folder], organizationVersion: 1, isManuallyArranged: true))
        let model = LauncherModel(repository: repository, preferences: preferences, preferredLanguages: ["zh-Hans"], scanApplications: { CatalogSnapshot(applications: []) })
        let before = try Data(contentsOf: repository.fileURL)
        var menuRefreshes = 0
        model.languageChanged = { menuRefreshes += 1 }
        #expect(model.title(for: folder) == "工具")
        model.language = .english
        #expect(model.title(for: folder) == "Utilities")
        #expect(model.text(.settingsTitle) == "LaunchTablet Settings")
        model.language = .english
        #expect(menuRefreshes == 1)
        #expect(try Data(contentsOf: repository.fileURL) == before)
        #expect(preferences.string(forKey: "interfaceLanguage") == "en")
        let reopened = LauncherModel(repository: repository, preferences: preferences, preferredLanguages: ["zh-Hans"])
        #expect(reopened.language == .english)
        model.language = .system
        #expect(model.title(for: folder) == "工具")
        #expect(menuRefreshes == 2)
    }

    @MainActor
    @Test func customFolderNamesStayUntranslated() throws {
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        let model = LauncherModel(repository: LayoutRepository(fileURL: directory.appendingPathComponent("layout.json")), preferences: preferences)
        var renamed = LauncherItem.categoryFolder(.utilities, applicationIDs: ["app"])
        renamed.folderName = "工作 Work"
        let custom = LauncherItem.folder(name: "工具", applicationIDs: ["other"])
        for language in [InterfaceLanguage.english, .simplifiedChinese] {
            model.language = language
            #expect(model.title(for: renamed) == "工作 Work")
            #expect(model.title(for: custom) == "工具")
        }
    }

    @MainActor
    @Test func existingErrorsAndWarningsFollowLanguageChanges() async throws {
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        let model = LauncherModel(repository: LayoutRepository(fileURL: directory.appendingPathComponent("layout.json")), preferences: preferences, preferredLanguages: ["en"], scanApplications: { CatalogSnapshot(applications: [], inaccessibleRoots: ["unavailable"]) })
        await model.refreshApplications().value
        model.failure = .shortcutUnavailable(.optionSpace)
        #expect(model.catalogWarning?.contains("unavailable") == true)
        #expect(model.errorText?.contains("Space") == true)
        model.language = .simplifiedChinese
        #expect(model.catalogWarning?.contains("暂时无法读取") == true)
        #expect(model.errorText?.contains("空格") == true)
        model.failure = .invalidLayout
        #expect(model.errorText?.contains("原文件已保留") == true)
        model.language = .english
        #expect(model.errorText?.contains("original file is preserved") == true)
    }

    @Test func preferenceMigrationCopiesOnlyMissingSupportedKeys() throws {
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        preferences.set("en", forKey: "interfaceLanguage")
        AppIdentity.migrateLegacyPreferences(to: preferences, legacyValues: ["shortcut": "optionSpace", "interfaceLanguage": "zh-Hans", "AppleLanguages": ["zh-Hans"]])
        #expect(preferences.string(forKey: "shortcut") == "optionSpace")
        #expect(preferences.string(forKey: "interfaceLanguage") == "en")
        #expect(preferences.persistentDomain(forName: suiteName)?["AppleLanguages"] == nil)
        AppIdentity.migrateLegacyPreferences(to: preferences, legacyValues: ["shortcut": "disabled"])
        #expect(preferences.string(forKey: "shortcut") == "optionSpace")
    }

    @Test func legacyLayoutIsReadWithoutOverwritingAndNewLayoutTakesPriority() throws {
        let legacy = LayoutRepository(fileURL: directory.appendingPathComponent("Launchpad/layout.json"))
        let original = LauncherLayout(items: [.folder(name: "我的工具", applicationIDs: ["a", "b"])], hiddenApplicationIDs: ["hidden"], organizationVersion: 1, isManuallyArranged: true)
        try legacy.save(original)
        let originalData = try Data(contentsOf: legacy.fileURL)
        let repository = LayoutRepository(fileURL: directory.appendingPathComponent("LaunchTablet/layout.json"), legacyFileURL: legacy.fileURL)
        #expect(try repository.load() == original)
        #expect(!FileManager.default.fileExists(atPath: repository.fileURL.path))
        var changed = original
        changed.items.append(.application("new"))
        try repository.save(changed)
        #expect(try repository.load() == changed)
        #expect(try Data(contentsOf: legacy.fileURL) == originalData)
        try Data("corrupt-new-layout".utf8).write(to: repository.fileURL)
        #expect(throws: (any Error).self) { try repository.load() }
        #expect(try Data(contentsOf: legacy.fileURL) == originalData)
    }

    @Test func newAndLegacyApplicationsAreExcludedFromCatalog() {
        for id in [AppIdentity.bundleIdentifier, AppIdentity.secondaryBundleIdentifier, AppIdentity.legacyBundleIdentifier, AppIdentity.legacySecondaryBundleIdentifier] {
            #expect(AppIdentity.isLauncher(bundleIdentifier: id))
        }
        #expect(!AppIdentity.isLauncher(bundleIdentifier: "com.example.another"))
        #expect(!AppIdentity.isLauncher(bundleIdentifier: nil))
    }

    @MainActor
    @Test func newlyCreatedFoldersUseSelectedLanguage() async throws {
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        preferences.set("en", forKey: "interfaceLanguage")
        let apps = (0..<4).map { InstalledApplication(id: "app-\($0)", url: URL(fileURLWithPath: "/tmp/App\($0).app"), name: "App\($0)", searchTerms: "app") }
        let model = LauncherModel(repository: LayoutRepository(fileURL: directory.appendingPathComponent("layout.json")), preferences: preferences, scanApplications: { CatalogSnapshot(applications: apps) })
        await model.refreshApplications().value
        model.createFolder(for: .application("app-0"))
        #expect(model.openFolder?.folderName == "Folder")
        model.closeFolder()
        model.beginDragging(.application("app-1"))
        #expect(model.performDrop(onto: .application("app-2"), grouping: true, after: false))
        #expect(model.layout.items.filter(\.isFolder).allSatisfy { $0.folderName == "Folder" })
        model.language = .simplifiedChinese
        model.createFolder(for: .application("app-3"))
        #expect(model.openFolder?.folderName == "文件夹")
    }
}
