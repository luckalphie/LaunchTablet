import Foundation
import Testing
@testable import LaunchTablet

private final class DelayedCatalog: @unchecked Sendable {
    let started = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var scans = 0
    let application = InstalledApplication(id: "new-app", url: URL(fileURLWithPath: "/tmp/New.app"), name: "New", searchTerms: "new")

    func scan() -> CatalogSnapshot {
        lock.lock()
        scans += 1
        let number = scans
        lock.unlock()
        if number == 1 {
            started.signal()
            _ = resume.wait(timeout: .now() + 10)
            return CatalogSnapshot(applications: [])
        }
        return CatalogSnapshot(applications: [application])
    }

    func waitForScan() -> Bool { started.wait(timeout: .now() + 5) == .success }
}

@Suite final class ApplicationDiscoveryTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private var suiteName: String { "LaunchTabletDiscoveryTests." + directory.lastPathComponent }

    deinit {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    @MainActor
    @Test func refreshDuringScanRunsAgainAndAddsNewApplication() async throws {
        let catalog = DelayedCatalog()
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        let repository = LayoutRepository(fileURL: directory.appendingPathComponent("layout.json"))
        let model = LauncherModel(repository: repository, preferences: preferences, scanApplications: { catalog.scan() })
        let first = model.refreshApplications()
        let started = await Task.detached { catalog.waitForScan() }.value
        #expect(started)
        _ = model.refreshApplications()
        catalog.resume.signal()
        await first.value
        #expect(model.applications.map(\.id) == ["new-app"])
        #expect(model.rootItems.map(\.applicationIDs) == [["new-app"]])
        #expect(try repository.load() == model.layout)
    }

    @MainActor
    @Test func nestedInstallationTriggersRefreshAndBrowserGrouping() async throws {
        let root = directory.appendingPathComponent("Applications")
        let nested = root.appendingPathComponent("Edge Apps.localized")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        let model = LauncherModel(repository: LayoutRepository(fileURL: directory.appendingPathComponent("layout.json")), preferences: preferences,
                                  scanApplications: { ApplicationCatalog.scan(roots: [root], includeFinder: false) })
        await model.refreshApplications().value
        let watcher = ApplicationDirectoryWatcher(roots: [root]) { model.scheduleRefresh() }
        let bundle = nested.appendingPathComponent("New Web.app/Contents")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "test.launchtablet.web", "CFBundleName": "New Web", "CFBundlePackageType": "APPL"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: bundle.appendingPathComponent("Info.plist"))
        #expect(ApplicationCatalog.scan(roots: [root], includeFinder: false).applications.contains { $0.id == "test.launchtablet.web" })
        for _ in 0..<100 {
            if model.layout.items.contains(where: { $0.folderCategory == .edge && $0.applicationIDs.contains("test.launchtablet.web") }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(model.applications.contains { $0.id == "test.launchtablet.web" })
        #expect(model.layout.items.contains { $0.folderCategory == .edge && $0.applicationIDs == ["test.launchtablet.web"] })
        withExtendedLifetime(watcher) {}
    }

    @MainActor
    @Test func newlyCreatedApplicationsDirectoryRemainsWatched() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let root = directory.appendingPathComponent("Applications")
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        let model = LauncherModel(repository: LayoutRepository(fileURL: directory.appendingPathComponent("layout.json")), preferences: preferences,
                                  scanApplications: { ApplicationCatalog.scan(roots: [root], includeFinder: false) })
        await model.refreshApplications().value
        let watcher = ApplicationDirectoryWatcher(roots: [root]) { model.scheduleRefresh() }
        try createApplication(id: "first", in: root)
        for _ in 0..<100 {
            if model.application(id: "first") != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(model.application(id: "first") != nil)
        try createApplication(id: "second", in: root.appendingPathComponent("Nested"))
        for _ in 0..<100 {
            if model.application(id: "second") != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(Set(model.applications.map(\.id)) == ["first", "second"])
        withExtendedLifetime(watcher) {}
    }

    private func createApplication(id: String, in parent: URL) throws {
        let contents = parent.appendingPathComponent("\(id).app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": id, "CFBundleName": id, "CFBundlePackageType": "APPL"]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }
}
