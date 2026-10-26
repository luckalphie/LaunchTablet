import Foundation
import Testing
@testable import LaunchTablet

@Suite struct ApplicationOrganizationTests {
    private func app(_ id: String, apple: Bool = false, date: TimeInterval? = nil, category: ApplicationCategory? = nil) -> InstalledApplication {
        InstalledApplication(id: id, url: URL(fileURLWithPath: "/Applications/\(id).app"), name: id, searchTerms: id, isAppleApplication: apple, installationDate: date.map(Date.init(timeIntervalSince1970:)), category: category)
    }

    @Test func applePrecedesThirdPartyAndInstallationDatesPrecedeNames() {
        let apps = [app("A-new", date: 200), app("Z-old", date: 100), app("Unknown"), app("Apple", apple: true, date: 300)]
        var layout = LauncherLayout()
        layout.reconcileApplications(apps, removeMissing: true)
        #expect(layout.items.flatMap(\.applicationIDs) == ["Apple", "Z-old", "A-new", "Unknown"])
        #expect(!layout.isManuallyArranged)
    }

    @Test func defaultFoldersKeepCommonAppsOnGridAndNeverDuplicate() {
        let apps = [app("Safari", apple: true), app("Terminal", apple: true, category: .other), app("Game", date: 100, category: .games), app("Dev", date: 50, category: .utilities), app("Browser", date: 60)]
        var layout = LauncherLayout()
        layout.reconcileApplications(apps + [apps[0]], removeMissing: true)
        #expect(layout.items.first == .application("Safari"))
        #expect(Set(layout.items.compactMap(\.folderName)) == ["其它", "游戏", "工具"])
        #expect(layout.items.flatMap(\.applicationIDs).count == apps.count)
        #expect(layout.items.contains(.application("Browser")))
    }

    @Test func categoriesUseExactMetadataAndKeepOrdinaryAppsVisible() {
        func category(_ value: String?, _ path: String = "/Applications/App.app", apple: Bool = false) -> ApplicationCategory? {
            ApplicationCategory.from(bundleCategory: value, path: path, isApple: apple, bundleID: "test")
        }
        #expect(category("public.app-category.utilities") == .utilities)
        #expect(category("public.app-category.developer-tools") == .utilities)
        #expect(category("public.app-category.productivity") == nil)
        #expect(category("public.app-category.board-games") == .games)
        #expect(category("public.app-category.role-playing-games") == .games)
        #expect(category("public.app-category.games") == .games)
        #expect(category(nil) == nil)
        #expect(category(nil, "/System/Applications/Utilities/Terminal.app", apple: true) == .other)
        #expect(category("public.app-category.utilities", apple: true) == nil)
        #expect(category(nil, "/Applications/游戏/Unknown.app") == .games)
        #expect(category("not-a-real-games") == nil)
    }

    @Test func updateKeepsFirstInstallationDateAndNewAppsJoinTheirCategory() {
        var layout = LauncherLayout()
        layout.reconcileApplications([app("Old", date: 100), app("New", date: 200), app("Tool", date: 50, category: .utilities)], removeMissing: true)
        layout.reconcileApplications([app("Old", date: 999), app("New", date: 200), app("Tool", date: 50, category: .utilities), app("NewTool", date: 300, category: .utilities)], removeMissing: true)
        #expect(layout.installationDates["Old"] == Date(timeIntervalSince1970: 100))
        #expect(layout.items.filter { !$0.isFolder }.flatMap(\.applicationIDs) == ["Old", "New"])
        #expect(layout.items.first(where: { $0.folderCategory == .utilities })?.applicationIDs == ["Tool", "NewTool"])
    }

    @Test func uninstallAndReinstallCaptureNewDate() {
        var layout = LauncherLayout()
        layout.reconcileApplications([app("App", date: 100)], removeMissing: true)
        layout.reconcileApplications([], removeMissing: true)
        #expect(layout.installationDates.isEmpty)
        layout.reconcileApplications([app("App", date: 300)], removeMissing: true)
        #expect(layout.installationDates["App"] == Date(timeIntervalSince1970: 300))
    }

    @Test func legacyAlphabeticalLayoutMigratesWhileManualOrderAndFoldersSurvive() throws {
        let data = Data(#"{"items":[{"id":"app:A","applicationIDs":["A"]},{"id":"app:B","applicationIDs":["B"]}],"hiddenApplicationIDs":[]}"#.utf8)
        var layout = try JSONDecoder().decode(LauncherLayout.self, from: data)
        let apps = [app("A", date: 200), app("B", apple: true)]
        layout.reconcileApplications(apps, removeMissing: true)
        #expect(layout.organizationVersion == 1)
        #expect(layout.items.flatMap(\.applicationIDs) == ["B", "A"])
        var manual = LauncherLayout(items: [.application("B"), .application("A")])
        manual.reconcileApplications([app("A", apple: true), app("B")], removeMissing: true)
        #expect(manual.isManuallyArranged)
        #expect(manual.items.flatMap(\.applicationIDs) == ["B", "A"])
        let folder = LauncherItem.folder(name: "我的工具", applicationIDs: ["A"])
        var custom = LauncherLayout(items: [folder, .application("B")])
        custom.reconcileApplications(apps, removeMissing: true)
        #expect(custom.isManuallyArranged)
        #expect(custom.items.first == folder)
    }

    @Test func partialScanDefersMigrationAndPreservesUnknownAndHiddenApps() {
        var layout = LauncherLayout(items: [.application("A"), .application("B")], hiddenApplicationIDs: ["Hidden"])
        layout.reconcileApplications([app("A")], removeMissing: false)
        #expect(layout.organizationVersion == 0)
        #expect(layout.items.flatMap(\.applicationIDs) == ["A", "B"])
        #expect(layout.hiddenApplicationIDs == ["Hidden"])
    }

    @Test func manualCategoryFolderReceivesNewAppsWithoutReorderingItsMembers() {
        var layout = LauncherLayout(items: [.categoryFolder(.games, applicationIDs: ["New", "Old"])], organizationVersion: 1, isManuallyArranged: true)
        layout.reconcileApplications([app("Old", date: 1, category: .games), app("New", date: 2, category: .games), app("Newest", date: 3, category: .games)], removeMissing: true)
        #expect(layout.items[0].applicationIDs == ["New", "Old", "Newest"])
        layout.dissolveFolder(id: layout.items[0].id)
        layout.reconcileApplications([app("Old", date: 1, category: .games), app("New", date: 2, category: .games), app("Newest", date: 3, category: .games)], removeMissing: true)
        #expect(!layout.items.contains { $0.isFolder })
    }

    @Test func resetDefaultKeepsHiddenStateAndCodablePreservesNewMetadata() throws {
        var layout = LauncherLayout(items: [.folder(name: "手动", applicationIDs: ["A"])], hiddenApplicationIDs: ["Hidden"], organizationVersion: 1, isManuallyArranged: true)
        layout.reconcileApplications([app("A", date: 1, category: .utilities), app("Hidden", date: 2)], removeMissing: true)
        layout.organizeDefault(applications: [app("A", date: 1, category: .utilities), app("Hidden", date: 2)])
        #expect(!layout.isManuallyArranged)
        #expect(layout.hiddenApplicationIDs == ["Hidden"])
        #expect(layout.items[0].folderCategory == .utilities)
        #expect(try JSONDecoder().decode(LauncherLayout.self, from: JSONEncoder().encode(layout)) == layout)
        #expect(throws: (any Error).self) { try JSONDecoder().decode(LauncherLayout.self, from: Data("{}".utf8)) }
    }

    @Test func browserDirectoryTakesPriorityAndDoesNotGroupBrowserItself() {
        #expect(ApplicationCategory.from(bundleCategory: "public.app-category.utilities", path: "/Users/test/Applications/Edge Apps.localized/Web.app", isApple: false, bundleID: "web") == .edge)
        #expect(ApplicationCategory.browserFolder(in: "/Users/test/Applications/Chrome Apps.localized/Profile/Web.app") == .chrome)
        #expect(ApplicationCategory.browserFolder(in: "/Applications/Chrome Apps/Web.app") == .chrome)
        #expect(ApplicationCategory.browserFolder(in: "/Applications/Microsoft Edge.app") == nil)
        #expect(ApplicationCategory.browserFolder(in: "/Applications/Google Chrome.app") == nil)
        #expect(ApplicationCategory.browserFolder(in: "/Applications/Not Edge Apps.localized/Web.app") == nil)
    }

    @Test func defaultBrowserFoldersAreSeparateAndPreserveInstallationOrder() {
        var layout = LauncherLayout()
        layout.reconcileApplications([app("EdgeNew", date: 200, category: .edge), app("ChromeWeb", date: 150, category: .chrome), app("EdgeOld", date: 100, category: .edge), app("Browser", date: 50)], removeMissing: true)
        #expect(layout.items[0] == .application("Browser"))
        #expect(layout.items[1].folderName == "Edge")
        #expect(layout.items[1].applicationIDs == ["EdgeOld", "EdgeNew"])
        #expect(layout.items[2].folderName == "Chrome")
        #expect(layout.items[2].applicationIDs == ["ChromeWeb"])
        #expect(layout.browserGroupingVersion == 1)
    }

    @Test func legacyManualBrowserMigrationPreservesCustomFoldersAndOtherPlacement() {
        let custom = LauncherItem.folder(name: "工作", applicationIDs: ["CustomWeb"])
        var layout = LauncherLayout(items: [.application("First"), .application("EdgeWeb"), .application("Second"), .categoryFolder(.utilities, applicationIDs: ["Tool", "ChromeWeb"]), custom], hiddenApplicationIDs: ["HiddenWeb"], organizationVersion: 1, isManuallyArranged: true)
        let apps = [app("First"), app("Second"), app("Tool", category: .utilities), app("EdgeWeb", category: .edge), app("ChromeWeb", category: .chrome), app("CustomWeb", category: .edge), app("HiddenWeb", category: .edge)]
        layout.reconcileApplications(apps, removeMissing: true)
        #expect(layout.items[0] == .application("First"))
        #expect(layout.items[1].folderCategory == .edge)
        #expect(layout.items[1].applicationIDs == ["EdgeWeb"])
        #expect(layout.items[2] == .application("Second"))
        #expect(layout.items.first(where: { $0.folderCategory == .utilities })?.applicationIDs == ["Tool"])
        #expect(layout.items.first(where: { $0.folderCategory == .chrome })?.applicationIDs == ["ChromeWeb"])
        #expect(layout.items.last == custom)
        #expect(layout.hiddenApplicationIDs == ["HiddenWeb"])
        let original = layout
        layout.reconcileApplications(apps, removeMissing: true)
        #expect(layout == original)
    }

    @Test func browserMigrationWaitsForFullScanAndNewWebAppsAlwaysJoinFolder() {
        var layout = LauncherLayout(items: [.application("Web")], organizationVersion: 1, isManuallyArranged: true)
        layout.reconcileApplications([app("Web", category: .edge)], removeMissing: false)
        #expect(layout.browserGroupingVersion == 0)
        #expect(layout.items == [.application("Web")])
        layout.reconcileApplications([app("Web", category: .edge)], removeMissing: true)
        #expect(layout.items[0].folderCategory == .edge)
        layout.reconcileApplications([app("Web", category: .edge), app("New", category: .edge), app("Chrome", category: .chrome)], removeMissing: true)
        #expect(layout.items[0].applicationIDs == ["Web", "New"])
        #expect(layout.items[1].folderCategory == .chrome)
        #expect(layout.items[1].applicationIDs == ["Chrome"])
        let reloaded = try? JSONDecoder().decode(LauncherLayout.self, from: JSONEncoder().encode(layout))
        #expect(reloaded == layout)
    }

    @Test func browserMigrationReusesRenamedBrowserFolderAndUserCanRearrangeAfterward() {
        var folder = LauncherItem.categoryFolder(.edge, applicationIDs: ["Existing"])
        folder.folderName = "网页应用"
        var layout = LauncherLayout(items: [.application("Loose"), folder], organizationVersion: 1, isManuallyArranged: true)
        let apps = [app("Existing", category: .edge), app("Loose", category: .edge)]
        layout.reconcileApplications(apps, removeMissing: true)
        #expect(layout.items.count == 1)
        #expect(layout.items[0].folderName == "网页应用")
        #expect(layout.items[0].applicationIDs == ["Existing", "Loose"])
        layout.removeFromFolder(applicationID: "Loose", folderID: folder.id)
        layout.reconcileApplications(apps, removeMissing: true)
        #expect(layout.items.last == .application("Loose"))
    }
}
