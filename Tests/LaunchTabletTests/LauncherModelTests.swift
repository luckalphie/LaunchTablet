import AppKit
import Testing
@testable import LaunchTablet

@Suite final class LauncherModelTests {
    @MainActor
    @Test func dragIntoOpenFolderAndBackToRootPersistsPlacement() async throws {
        let model = try makeModel(count: 5)
        await model.refreshApplications().value
        model.createFolder(for: .application("id-0"))
        let folder = try #require(model.openFolder)
        model.closeFolder()
        model.beginDragging(.application("id-1"))
        model.activate(folder)
        #expect(model.performDrop(onto: .application("id-0"), grouping: false, after: false))
        #expect(model.folderItems.map(\.id) == ["app:id-1", "app:id-0"])
        model.beginDragging(.application("id-1"))
        model.closeFolder()
        #expect(model.performDrop(onto: .application("id-3"), grouping: false, after: true))
        #expect(model.rootItems.map(\.id) == [folder.id, "app:id-2", "app:id-3", "app:id-1", "app:id-4"])
        #expect(model.layout.items[0].applicationIDs == ["id-0"])
        let saved = try LayoutRepository(fileURL: directory.appendingPathComponent("layout.json")).load()
        #expect(saved == model.layout)
    }

    @MainActor
    @Test func dragToExistingFolderAndAcrossFolders() async throws {
        let model = try makeModel(count: 5)
        await model.refreshApplications().value
        model.createFolder(for: .application("id-0"))
        let first = try #require(model.openFolder)
        model.closeFolder()
        model.createFolder(for: .application("id-1"))
        let second = try #require(model.openFolder)
        model.closeFolder()
        model.beginDragging(.application("id-2"))
        #expect(model.performDrop(onto: first, grouping: true, after: false))
        model.activate(first)
        model.beginDragging(.application("id-2"))
        model.closeFolder()
        model.activate(second)
        #expect(model.dropIntoEmptySlot())
        #expect(model.folderItems.map(\.id) == ["app:id-1", "app:id-2"])
        #expect(model.layout.items.first(where: { $0.id == first.id })?.applicationIDs == ["id-0"])
        #expect(Set(model.layout.items.flatMap(\.applicationIDs)).count == 5)
    }

    @MainActor
    @Test func canceledHoverNeverChangesLayoutOrLeavesDragFeedback() async throws {
        let model = try makeModel(count: 5)
        await model.refreshApplications().value
        let original = model.layout
        model.beginDragging(model.rootItems[0])
        model.updateDropTarget(model.rootItems[1].id, grouping: true)
        #expect(!model.isGroupingDrop)
        model.endDragging()
        try await Task.sleep(for: .milliseconds(550))
        #expect(model.layout == original)
        #expect(model.draggedItemID == nil)
        #expect(model.dropTargetID == nil)
        #expect(!model.isGroupingDrop)
        #expect(!model.dropIntoEmptySlot())
    }

    @MainActor
    @Test func folderHoverOpensThenOutsideHoverClosesWithoutMovingSource() async throws {
        let model = try makeModel(count: 5)
        await model.refreshApplications().value
        model.createFolder(for: .application("id-0"))
        let folder = try #require(model.openFolder)
        model.closeFolder()
        let original = model.layout
        model.beginDragging(.application("id-1"))
        model.updateDropTarget(folder.id, grouping: true)
        #expect(model.isGroupingDrop)
        // CI 负载波动时定时任务可能晚于理论时间，等待实际状态变化再验证。
        for _ in 0..<30 {
            if model.openFolderID == folder.id { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(model.openFolderID == folder.id)
        #expect(model.draggedItemID == "app:id-1")
        model.beginFolderExitHover()
        for _ in 0..<30 {
            if model.openFolderID == nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(model.openFolderID == nil)
        #expect(model.layout == original)
        model.endDragging()
    }

    @MainActor
    @Test func appHoverArmsGroupingButMovingToEdgeDisarmsIt() async throws {
        let model = try makeModel(count: 5)
        await model.refreshApplications().value
        model.beginDragging(model.rootItems[0])
        model.updateDropTarget(model.rootItems[1].id, grouping: true)
        for _ in 0..<30 {
            if model.isGroupingDrop { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(model.isGroupingDrop)
        model.updateDropTarget(model.rootItems[1].id, grouping: false, after: true)
        #expect(!model.isGroupingDrop)
        #expect(model.dropAfter)
        model.endDragging()
        model.query = "App"
        model.beginDragging(.application("id-0"))
        #expect(model.draggedItemID == nil)
    }

    @MainActor
    @Test func rootFolderCannotBeDraggedInsideAnotherFolder() async throws {
        let model = try makeModel(count: 5)
        await model.refreshApplications().value
        model.createFolder(for: .application("id-0"))
        let first = try #require(model.openFolder)
        model.closeFolder()
        model.createFolder(for: .application("id-1"))
        let second = try #require(model.openFolder)
        model.closeFolder()
        let original = model.layout
        model.beginDragging(first)
        #expect(!model.canGroup(onto: second))
        model.activate(second)
        #expect(!model.dropIntoEmptySlot())
        #expect(model.layout == original)
    }

    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    deinit {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: "LaunchTabletTests." + directory.lastPathComponent)
    }

    @MainActor
    private func makeModel(count: Int = 71) throws -> LauncherModel {
        let applications = (0..<count).map { index in
            InstalledApplication(id: "id-\(index)", url: URL(fileURLWithPath: "/Applications/App\(index).app"), name: "App\(index)", searchTerms: "app\(index)")
        }
        let repository = LayoutRepository(fileURL: directory.appendingPathComponent("layout.json"))
        // 这些用例检查手动布局的键盘/分页行为；默认分类与迁移有独立用例。
        try repository.save(LauncherLayout(organizationVersion: 1, isManuallyArranged: true))
        return LauncherModel(repository: repository, preferences: UserDefaults(suiteName: "LaunchTabletTests." + directory.lastPathComponent)!, scanApplications: { CatalogSnapshot(applications: applications) })
    }

    private func key(_ code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }

    private func preciseScroll(x: Int32, y: Int32 = 0, phase: CGScrollPhase? = nil, momentum: CGMomentumScrollPhase = .none) -> NSEvent {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0)!
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        // CGEvent 与 NSEvent 的阶段枚举编号不同，必须使用底层 CG 枚举构造，不能直接强转 rawValue。
        event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase?.rawValue ?? 0))
        event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue))
        return NSEvent(cgEvent: event)!
    }

    @MainActor
    @Test func testPaginationBoundariesAndSearchRestoresBrowsePage() async throws {
        let model = try makeModel()
        await model.refreshApplications().value
        #expect(model.rootPageCount == 3)
        model.setPage(200)
        #expect(model.page == 2)
        model.query = "app70"
        #expect(model.page == 0)
        #expect(model.rootItems.map(\.applicationIDs) == [["id-70"]])
        model.query = ""
        #expect(model.page == 2)
        #expect(LauncherModel.pageCount(itemCount: 35, capacity: 35) == 1)
        #expect(LauncherModel.pageCount(itemCount: 36, capacity: 35) == 2)
        #expect(LauncherModel.pageCount(itemCount: 0, capacity: 35) == 1)
    }

    @MainActor
    @Test func testEscapeClosesFolderThenClearsSearchThenDismisses() async throws {
        let model = try makeModel()
        await model.refreshApplications().value
        var dismissCount = 0
        model.dismissRequested = { dismissCount += 1 }
        model.createFolder(for: model.rootItems[0])
        #expect(model.openFolderID != nil)
        #expect(model.handleKey(key(53)))
        #expect(model.openFolderID == nil)
        #expect(dismissCount == 0)
        model.query = "app"
        #expect(model.handleKey(key(53)))
        #expect(model.query == "")
        #expect(dismissCount == 0)
        #expect(model.handleKey(key(53)))
        #expect(dismissCount == 1)
    }

    @MainActor
    @Test func testKeyboardNavigationChangesPageAndKeepsSelectionVisible() async throws {
        let model = try makeModel()
        await model.refreshApplications().value
        #expect(model.handleKey(key(125)))
        #expect(model.selectedItemID == "app:id-0")
        for _ in 0..<35 { #expect(model.handleKey(key(124))) }
        #expect(model.page == 1)
        #expect(model.selectedItemID == "app:id-35")
        #expect(model.handleKey(key(123)))
        #expect(model.page == 0)
        #expect(model.selectedItemID == "app:id-34")
    }

    @MainActor
    @Test func testSearchArrowKeysPreserveTextEditingBeforeGridNavigation() async throws {
        let model = try makeModel()
        await model.refreshApplications().value
        model.query = "app"
        #expect(!(model.handleKey(key(123))))
        #expect(!(model.handleKey(key(124))))
        #expect(model.handleKey(key(125)))
        #expect(model.handleKey(key(124)))
        #expect(model.selectedItemID == "app:id-1")
    }

    @MainActor
    @Test func testFolderDropPersistsAndSelectionClampsAfterRemoval() async throws {
        let model = try makeModel(count: 36)
        await model.refreshApplications().value
        let source = model.rootItems[0]
        let target = model.rootItems[1]
        model.setPage(1)
        model.beginDragging(source)
        #expect(model.performDrop(onto: target, grouping: true, after: false))
        #expect(model.rootItems.count == 35)
        #expect(model.page == 0)
        #expect(model.rootItems[0].isFolder)
        #expect(model.rootItems[0].applicationIDs == ["id-1", "id-0"])
        #expect(model.draggedItemID == nil)
    }

    @MainActor
    @Test func testOnlyOnePagePerTrackpadGestureAndMomentumIsIgnored() async throws {
        let model = try makeModel(count: 150)
        await model.refreshApplications().value
        #expect(model.handleScroll(preciseScroll(x: -70, phase: .began)))
        #expect(model.page == 1)
        let moving = preciseScroll(x: -200, phase: .changed)
        #expect(moving.phase.contains(.changed))
        #expect(model.handleScroll(moving))
        #expect(model.page == 1)
        #expect(model.handleScroll(preciseScroll(x: 0, phase: .ended)))
        let momentum = preciseScroll(x: -100, momentum: .begin)
        #expect(momentum.momentumPhase.contains(.began))
        #expect(model.handleScroll(momentum))
        #expect(model.page == 1)
        #expect(model.handleScroll(preciseScroll(x: -70, phase: .began)))
        #expect(model.page == 2)
    }

    @Test func testSearchSupportsCaseDiacriticsAndMultipleTerms() {
        let app = InstalledApplication(id: "id", url: URL(fileURLWithPath: "/tmp/app"), name: "终端", searchTerms: "终端 terminal zhong duan zhongduan zd")
        #expect(app.matches("TERMINAL"))
        #expect(app.matches("zhōng duàn"))
        #expect(app.matches("zd"))
        #expect(!(app.matches("missing")))
    }

    @MainActor
    @Test func testSettingsKeepsArrowKeysAndEscapeOnlyClosesPopover() async throws {
        let model = try makeModel()
        await model.refreshApplications().value
        var dismissed = false
        model.dismissRequested = { dismissed = true }
        model.isSettingsPresented = true
        #expect(!model.handleKey(key(125)))
        #expect(model.selectedItemID == nil)
        #expect(model.handleKey(key(53)))
        #expect(!model.isSettingsPresented)
        #expect(!dismissed)
    }

    @MainActor
    @Test func testDropOntoLastPageEmptySlotMovesApplicationToEnd() async throws {
        let model = try makeModel(count: 36)
        await model.refreshApplications().value
        model.beginDragging(model.rootItems[0])
        model.setPage(1)
        #expect(model.dropIntoEmptySlot())
        #expect(model.rootItems.last?.applicationIDs == ["id-0"])
        #expect(model.rootItems.count == 36)
        #expect(model.page == 1)
    }

    @MainActor
    @Test func testInvalidFolderTargetDoesNotRemoveDraggedChild() async throws {
        let model = try makeModel(count: 4)
        await model.refreshApplications().value
        model.beginDragging(model.rootItems[0])
        #expect(model.performDrop(onto: model.rootItems[1], grouping: true, after: false))
        model.activate(model.rootItems[0])
        let original = model.layout
        model.beginDragging(model.folderItems[0])
        #expect(!model.performDrop(onto: .application("not-in-folder"), grouping: false, after: false))
        #expect(model.layout == original)
    }

    @MainActor
    @Test func testPreciseVerticalWheelAlsoTurnsHorizontalPage() async throws {
        let model = try makeModel(count: 150)
        await model.refreshApplications().value
        #expect(model.handleScroll(preciseScroll(x: 0, y: -648)))
        #expect(model.page == 1)
    }

    @MainActor
    @Test func testDiagonalGestureKeepsItsInitialAxis() async throws {
        let model = try makeModel(count: 150)
        await model.refreshApplications().value
        #expect(model.handleScroll(preciseScroll(x: -10, y: -2, phase: .began)))
        #expect(model.handleScroll(preciseScroll(x: -5, y: -80, phase: .changed)))
        #expect(model.page == 0)
        #expect(model.handleScroll(preciseScroll(x: -45, phase: .changed)))
        #expect(model.page == 1)
    }
}
