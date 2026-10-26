import Foundation
import Testing
@testable import LaunchTablet

@Suite final class LauncherLayoutTests {
    @Test func crossFolderMoveIsAtomicAndRemovesEmptySource() {
        let source = LauncherItem.folder(name: "来源", applicationIDs: ["a"])
        let destination = LauncherItem.folder(name: "目标", applicationIDs: ["b", "c"])
        var layout = LauncherLayout(items: [source, destination])
        let movedAcrossFolders = layout.moveApplication(applicationID: "a", fromFolderID: source.id, toFolderID: destination.id, relativeTo: "app:c", after: false)
        #expect(movedAcrossFolders)
        #expect(layout.items.count == 1)
        #expect(layout.items[0].applicationIDs == ["b", "a", "c"])
    }

    @Test func folderChildCanMoveToRootAndBackWithoutDuplicates() {
        let folder = LauncherItem.folder(name: "工具", applicationIDs: ["a", "b"])
        var layout = LauncherLayout(items: [folder, .application("c")])
        let movedToRoot = layout.moveApplication(applicationID: "b", fromFolderID: folder.id, toFolderID: nil, relativeTo: "app:c", after: true)
        #expect(movedToRoot)
        #expect(layout.items.flatMap(\.applicationIDs) == ["a", "c", "b"])
        let movedBackIntoFolder = layout.moveApplication(applicationID: "b", fromFolderID: nil, toFolderID: folder.id, relativeTo: "app:a", after: false)
        #expect(movedBackIntoFolder)
        #expect(layout.items[0].applicationIDs == ["b", "a"])
        #expect(layout.items.count == 2)
        let reorderedWithinFolder = layout.moveApplication(applicationID: "b", fromFolderID: folder.id, toFolderID: folder.id, relativeTo: "app:a", after: true)
        #expect(reorderedWithinFolder)
        #expect(layout.items[0].applicationIDs == ["a", "b"])
        let unchangedOrderRejected = !layout.moveApplication(applicationID: "b", fromFolderID: folder.id, toFolderID: folder.id, relativeTo: nil, after: true)
        #expect(unchangedOrderRejected)
    }

    @Test func invalidCrossContainerTargetsLeaveEntireLayoutUntouched() {
        let folder = LauncherItem.folder(name: "工具", applicationIDs: ["a"])
        var layout = LauncherLayout(items: [folder, .application("b")])
        let original = layout
        let missingFolderRejected = !layout.moveApplication(applicationID: "a", fromFolderID: folder.id, toFolderID: "missing", relativeTo: nil, after: true)
        #expect(missingFolderRejected)
        let missingRootTargetRejected = !layout.moveApplication(applicationID: "a", fromFolderID: folder.id, toFolderID: nil, relativeTo: "missing", after: true)
        #expect(missingRootTargetRejected)
        let invalidChildTargetRejected = !layout.moveApplication(applicationID: "b", fromFolderID: nil, toFolderID: folder.id, relativeTo: "app:b", after: false)
        #expect(invalidChildTargetRejected)
        let missingSourceRejected = !layout.groupApplication(applicationID: "missing", fromFolderID: folder.id, into: "app:b")
        #expect(missingSourceRejected)
        let ownFolderRejected = !layout.groupApplication(applicationID: "a", fromFolderID: folder.id, into: folder.id)
        #expect(ownFolderRejected)
        #expect(layout == original)
    }

    @Test func folderChildCanFormNewFolderWithRootApplication() {
        let folder = LauncherItem.folder(name: "来源", applicationIDs: ["a"])
        var layout = LauncherLayout(items: [folder, .application("b"), .application("c")])
        let createdFolder = layout.groupApplication(applicationID: "a", fromFolderID: folder.id, into: "app:b")
        #expect(createdFolder)
        #expect(layout.items.count == 2)
        #expect(layout.items[0].isFolder)
        #expect(layout.items[0].applicationIDs == ["b", "a"])
        #expect(layout.items[1] == .application("c"))
    }

    @Test func testReconcileKeepsPlacementAndAddsNewApplicationsOnce() {
        var layout = LauncherLayout(items: [.application("b"), .folder(name: "工具", applicationIDs: ["a", "removed", "b"])], hiddenApplicationIDs: ["hidden"])
        layout.reconcile(applicationIDs: ["a", "b", "new", "new", "hidden"])
        #expect(layout.items[0] == .application("b"))
        #expect(layout.items[1].applicationIDs == ["a"])
        #expect(layout.items[1].folderName == "工具")
        #expect(layout.items[2] == .application("new"))
        #expect(layout.items.count == 3)
    }

    @Test func testPartialScanDoesNotRemoveExistingOrHiddenApplications() {
        var layout = LauncherLayout(items: [.application("unreadable"), .application("known")], hiddenApplicationIDs: ["hidden"])
        layout.reconcile(applicationIDs: ["known", "new"], removeMissing: false)
        #expect(layout.items.flatMap(\.applicationIDs) == ["unreadable", "known", "new"])
        #expect(layout.hiddenApplicationIDs == ["hidden"])
    }

    @Test func testMoveHandlesBothDirectionsWithoutIndexShift() {
        var layout = LauncherLayout(items: ["a", "b", "c", "d"].map(LauncherItem.application))
        layout.move(itemID: "app:a", relativeTo: "app:c", after: true)
        #expect(layout.items.flatMap(\.applicationIDs) == ["b", "c", "a", "d"])
        layout.move(itemID: "app:d", relativeTo: "app:b", after: false)
        #expect(layout.items.flatMap(\.applicationIDs) == ["d", "b", "c", "a"])
    }

    @Test func testInvalidMoveDoesNotLoseSource() {
        var layout = LauncherLayout(items: [.application("a")])
        let original = layout
        layout.move(itemID: "app:a", relativeTo: "missing", after: true)
        layout.group(itemID: "app:a", into: "missing")
        #expect(layout == original)
    }

    @Test func testGroupingHandlesSourceBeforeTargetAndAddsToFolder() {
        var layout = LauncherLayout(items: ["a", "b", "c"].map(LauncherItem.application))
        layout.group(itemID: "app:a", into: "app:c")
        #expect(layout.items[0] == .application("b"))
        #expect(layout.items[1].applicationIDs == ["c", "a"])
        let folderID = layout.items[1].id
        layout.group(itemID: "app:b", into: folderID)
        #expect(layout.items.count == 1)
        #expect(layout.items[0].applicationIDs == ["c", "a", "b"])
    }

    @Test func testFolderCannotBeNestedOrLoseItsApplications() {
        let folder = LauncherItem.folder(name: "工具", applicationIDs: ["a", "b"])
        var layout = LauncherLayout(items: [folder, .application("c")])
        let original = layout
        layout.group(itemID: folder.id, into: "app:c")
        #expect(layout == original)
    }

    @Test func testDissolvePreservesChildOrderAndPosition() {
        let folder = LauncherItem.folder(name: "工具", applicationIDs: ["b", "a"])
        var layout = LauncherLayout(items: [.application("first"), folder, .application("last")])
        layout.dissolveFolder(id: folder.id)
        #expect(layout.items.flatMap(\.applicationIDs) == ["first", "b", "a", "last"])
    }

    @Test func testRemoveLastApplicationRemovesEmptyFolder() {
        let folder = LauncherItem.folder(name: "工具", applicationIDs: ["a"])
        var layout = LauncherLayout(items: [folder, .application("b")])
        layout.removeFromFolder(applicationID: "a", folderID: folder.id)
        #expect(layout.items == [.application("a"), .application("b")])
    }

    @Test func testHideAndRestoreDoNotDuplicateFolderChildren() {
        let folder = LauncherItem.folder(name: "工具", applicationIDs: ["a", "b"])
        var layout = LauncherLayout(items: [folder])
        layout.hide(applicationID: "a")
        layout.reconcile(applicationIDs: ["a", "b"])
        #expect(layout.items[0].applicationIDs == ["b"])
        layout.hiddenApplicationIDs.remove("a")
        layout.reconcile(applicationIDs: ["a", "b"])
        #expect(layout.items.flatMap(\.applicationIDs) == ["b", "a"])
    }

    @Test func testRepositoryRoundTripAndCorruptFileIsNotOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = LayoutRepository(fileURL: directory.appendingPathComponent("layout.json"))
        #expect(try repository.load() == LauncherLayout())
        let layout = LauncherLayout(items: [.folder(name: "开发", applicationIDs: ["a", "b"])], hiddenApplicationIDs: ["hidden"])
        try repository.save(layout)
        #expect(try repository.load() == layout)
        let corrupt = Data("invalid-json".utf8)
        try corrupt.write(to: repository.fileURL)
        #expect(throws: (any Error).self) { try repository.load() }
        #expect(try Data(contentsOf: repository.fileURL) == corrupt)
    }

    @Test func testLegacyLayoutCreatesStableCategoryFoldersOnce() {
        let date1 = Date(timeIntervalSince1970: 100)
        let date2 = Date(timeIntervalSince1970: 200)
        let apps = [
            InstalledApplication(id: "third-new", url: URL(fileURLWithPath: "/Applications/New.app"), name: "New", searchTerms: "new", installationDate: date2, category: .other),
            InstalledApplication(id: "apple-tool", url: URL(fileURLWithPath: "/System/Applications/Terminal.app"), name: "Terminal", searchTerms: "terminal", isAppleApplication: true, installationDate: date2, category: .utilities),
            InstalledApplication(id: "third-old", url: URL(fileURLWithPath: "/Applications/Old.app"), name: "Old", searchTerms: "old", installationDate: date1, category: .other),
            InstalledApplication(id: "game", url: URL(fileURLWithPath: "/Applications/Game.app"), name: "Game", searchTerms: "game", installationDate: date1, category: .games)
        ]
        var layout = LauncherLayout(items: apps.map { .application($0.id) })
        layout.organizeDefault(applications: apps)
        #expect(layout.items.map(\.folderName) == ["工具", "游戏", "其它"])
        #expect(layout.items[0].applicationIDs == ["apple-tool"])
        #expect(layout.items[2].applicationIDs == ["third-old", "third-new"])
        let before = layout
        layout.organizeDefault(applications: apps.reversed())
        #expect(layout == before)
    }
}
