import Foundation
import Testing
@testable import LaunchTablet

@Suite final class GridDisplayModeTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private let suiteName = "LaunchTabletGridTests." + UUID().uuidString

    deinit {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
    }

    @Test func largeScreensUseSelectedAreaAndFullScreenHasNoNotebookCap() {
        let screen = CGSize(width: 2560, height: 1440)
        let compact = GridMetrics(screenSize: screen, displayMode: .macBook14)
        let spacious = GridMetrics(screenSize: screen, displayMode: .macBook16)
        let desktop24 = GridMetrics(screenSize: screen, displayMode: .display24)
        let desktop27 = GridMetrics(screenSize: screen, displayMode: .display27)
        let full = GridMetrics(screenSize: screen, displayMode: .fullScreen)
        #expect(compact.width == 1120 && compact.height == 790)
        #expect(spacious.width == 1280 && spacious.height == 900)
        #expect(desktop24.width == 1920 && desktop24.height == 1080)
        #expect(desktop27.width == 2160 && desktop27.height == 1215)
        #expect(desktop24.iconSize > spacious.iconSize && desktop27.iconSize > desktop24.iconSize)
        #expect(full.width == 2048 && full.height == 1296)
        #expect(compact.columns == spacious.columns && spacious.columns == full.columns)
        #expect(compact.rows == spacious.rows && spacious.rows == full.rows)
    }

    @Test func pageViewportsUseScreenEdgesOrOneColumnGutters() {
        let largeScreen = CGSize(width: 3840, height: 2160)
        for mode in GridDisplayMode.allCases {
            let metrics = GridMetrics(screenSize: largeScreen, displayMode: mode)
            let contentWidth = metrics.width - GridMetrics.horizontalGridPadding * 2
            let columnPitch = (contentWidth + GridMetrics.cellSpacing) / CGFloat(metrics.columns)
            let paging = PageViewportMetrics(contentWidth: contentWidth, viewportWidth: metrics.pageViewportWidth)
            if mode == .fullScreen { #expect(paging.viewportWidth == largeScreen.width) }
            else { #expect(paging.contentInset >= columnPitch - 0.000001) }
            #expect(paging.viewportWidth <= largeScreen.width)
        }
        // 小屏空间不足一列时，动画尽可能延伸到屏幕边缘，不缩小静止网格。
        let small = GridMetrics(screenSize: CGSize(width: 800, height: 600), displayMode: .macBook14)
        #expect(small.width == 712)
        #expect(small.pageViewportWidth == 800)
    }

    @Test func widerViewportsKeepRestingPagesCenteredWithoutShowingNeighbors() {
        let screen = CGSize(width: 3840, height: 2160)
        for mode in GridDisplayMode.allCases {
            let metrics = GridMetrics(screenSize: screen, displayMode: mode)
            let paging = PageViewportMetrics(contentWidth: metrics.width - GridMetrics.horizontalGridPadding * 2, viewportWidth: metrics.pageViewportWidth)
            let originOnScreen = (screen.width - paging.viewportWidth) / 2 + paging.contentInset
            #expect(abs(originOnScreen - (screen.width - paging.contentWidth) / 2) < 0.000001)
            for currentPage in 0..<3 {
                let offset = -CGFloat(currentPage) * paging.pageStride
                let currentStart = CGFloat(currentPage) * paging.pageStride + paging.contentInset + offset
                #expect(abs(currentStart - paging.contentInset) < 0.000001)
                let previousEnd = CGFloat(currentPage - 1) * paging.pageStride + paging.contentInset + paging.contentWidth + offset
                let nextStart = CGFloat(currentPage + 1) * paging.pageStride + paging.contentInset + offset
                #expect(previousEnd <= 0.000001)
                #expect(nextStart >= paging.viewportWidth - 0.000001)
            }
        }
        // 文件夹未指定外扩视口，继续在其面板内部裁切。
        let folder = PageViewportMetrics(contentWidth: 624)
        #expect(folder.viewportWidth == 624 && folder.contentInset == 0)
    }

    @Test func transitionFramesCanTravelBeyondBothGridEdges() {
        for mode in GridDisplayMode.allCases {
            let metrics = GridMetrics(screenSize: CGSize(width: 3840, height: 2160), displayMode: mode)
            let paging = PageViewportMetrics(contentWidth: metrics.width - GridMetrics.horizontalGridPadding * 2, viewportWidth: metrics.pageViewportWidth)
            let fraction: CGFloat = 0.3
            let outgoingStart = paging.contentInset - paging.pageStride * fraction
            let incomingStart = paging.pageStride + outgoingStart
            #expect(outgoingStart < paging.contentInset)
            #expect(outgoingStart + paging.contentWidth > 0)
            #expect(incomingStart < paging.viewportWidth)
            #expect(incomingStart + paging.contentWidth > paging.contentInset + paging.contentWidth)
            #expect(paging.pageStride > paging.contentWidth)
        }
    }

    @Test func smallScreensShrinkAllModesAndKeepGridThresholds() {
        let screen = CGSize(width: 800, height: 600)
        let metrics = GridDisplayMode.allCases.map { GridMetrics(screenSize: screen, displayMode: $0) }
        #expect(metrics.allSatisfy { $0.width <= 712 && $0.height == 528 })
        #expect(metrics[0].width == 640)
        #expect(metrics.allSatisfy { $0.columns == 5 && $0.rows == 4 && (42...78).contains($0.iconSize) })
        let boundary = GridMetrics(screenSize: CGSize(width: 848, height: 632), displayMode: .macBook14)
        #expect(boundary.columns == 7 && boundary.rows == 5)
        let below = GridMetrics(screenSize: CGSize(width: 847, height: 631), displayMode: .macBook14)
        #expect(below.columns == 5 && below.rows == 4)
        // SwiftUI 初次布局可能先给零尺寸，不能产生负数、无穷或 NaN。
        let initial = GridMetrics(screenSize: .zero, displayMode: .fullScreen)
        #expect(initial.width == 1 && initial.height == 1 && initial.iconSize.isFinite)
    }

    @Test func fullScreenIconsGrowWithScreenAndLeaveRoomForCaptions() {
        let screens = [CGSize(width: 1440, height: 900), CGSize(width: 1920, height: 1080), CGSize(width: 2560, height: 1440), CGSize(width: 3840, height: 2160)]
        var previousSize: CGFloat = 78
        for screen in screens {
            let metrics = GridMetrics(screenSize: screen, displayMode: .fullScreen)
            #expect(metrics.iconSize > previousSize)
            #expect(metrics.iconSize <= 160)
            let cellHeight = (metrics.height - 142 - CGFloat(metrics.rows - 1) * GridMetrics.cellSpacing) / CGFloat(metrics.rows)
            let contentHeight = metrics.iconSize + GridMetrics.captionFontSize(for: metrics.iconSize) * 1.3 + GridMetrics.captionSpacing(for: metrics.iconSize) + 10
            #expect(contentHeight <= cellHeight)
            previousSize = metrics.iconSize
        }
        let compact = GridMetrics(screenSize: screens[3], displayMode: .macBook14)
        let spacious = GridMetrics(screenSize: screens[3], displayMode: .macBook16)
        #expect(compact.iconSize == 78 && spacious.iconSize == 78)
    }

    @Test func fullScreenInsetsBalanceWideAndPortraitScreens() {
        let landscapeScreen = CGSize(width: 2560, height: 1440)
        let landscape = GridMetrics(screenSize: landscapeScreen, displayMode: .fullScreen)
        #expect((landscapeScreen.width - landscape.width) / 2 == 256)
        #expect((landscapeScreen.height - landscape.height) / 2 == 72)
        let ultraWideScreen = CGSize(width: 3440, height: 1440)
        let ultraWide = GridMetrics(screenSize: ultraWideScreen, displayMode: .fullScreen)
        #expect(ultraWide.width / ultraWide.height <= 1.9 + 0.000001)
        #expect((ultraWideScreen.width - ultraWide.width) / 2 > ultraWideScreen.width * 0.1)
        #expect(ultraWide.iconSize == landscape.iconSize)
        let portrait = GridMetrics(screenSize: CGSize(width: 1080, height: 1920), displayMode: .fullScreen)
        #expect(portrait.width == 864 && portrait.height == 1728)
        #expect(portrait.columns == 5 && portrait.rows == 7)
        #expect(portrait.columns * portrait.rows == landscape.columns * landscape.rows)
        #expect(portrait.iconSize > 78)
    }

    @MainActor
    @Test func missingAndUnknownPreferencesKeepFourteenInchDefault() throws {
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        let repository = LayoutRepository(fileURL: directory.appendingPathComponent("layout.json"))
        let original = LauncherLayout(items: [.folder(name: "工作", applicationIDs: ["app"])], hiddenApplicationIDs: ["hidden"], organizationVersion: 1, isManuallyArranged: true)
        try repository.save(original)
        let before = try Data(contentsOf: repository.fileURL)
        let initial = LauncherModel(repository: repository, preferences: preferences)
        #expect(initial.gridDisplayMode == .macBook14)
        preferences.set("unknown-future-mode", forKey: "gridDisplayMode")
        let unknown = LauncherModel(repository: repository, preferences: preferences)
        #expect(unknown.gridDisplayMode == .macBook14)
        #expect(try Data(contentsOf: repository.fileURL) == before)
    }

    @MainActor
    @Test func selectedAreaPersistsAcrossRestartsWithoutRewritingLayout() throws {
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        let repository = LayoutRepository(fileURL: directory.appendingPathComponent("layout.json"))
        try repository.save(LauncherLayout(items: [.folder(name: "Work", applicationIDs: ["app"])], hiddenApplicationIDs: ["hidden"], organizationVersion: 1, isManuallyArranged: true))
        let model = LauncherModel(repository: repository, preferences: preferences)
        let before = try Data(contentsOf: repository.fileURL)
        for mode in GridDisplayMode.allCases {
            model.gridDisplayMode = mode
            #expect(preferences.string(forKey: "gridDisplayMode") == mode.rawValue)
            let reopened = LauncherModel(repository: repository, preferences: preferences)
            #expect(reopened.gridDisplayMode == mode)
            #expect(reopened.layout == model.layout)
            #expect(try Data(contentsOf: repository.fileURL) == before)
        }
    }

    @MainActor
    @Test func changingAreaKeepsPageSearchAndFolderState() async throws {
        let preferences = try #require(UserDefaults(suiteName: suiteName))
        let apps = (0..<80).map { InstalledApplication(id: "app-\($0)", url: URL(fileURLWithPath: "/tmp/App\($0).app"), name: "App\($0)", searchTerms: "app") }
        let folder = LauncherItem.folder(name: "Work", applicationIDs: ["app-0", "app-1"])
        let layout = LauncherLayout(items: [folder] + apps.dropFirst(2).map { .application($0.id) }, organizationVersion: 1, isManuallyArranged: true)
        let repository = LayoutRepository(fileURL: directory.appendingPathComponent("layout.json"))
        try repository.save(layout)
        let model = LauncherModel(repository: repository, preferences: preferences, scanApplications: { CatalogSnapshot(applications: apps) })
        await model.refreshApplications().value
        let scannedLayout = model.layout
        model.setPage(2)
        for mode in GridDisplayMode.allCases {
            model.gridDisplayMode = mode
            let metrics = GridMetrics(screenSize: CGSize(width: 2560, height: 1440), displayMode: mode)
            model.updateGrid(columns: metrics.columns, rows: metrics.rows)
            #expect(model.page == 2)
            #expect(model.layout == scannedLayout)
        }
        model.query = "App"
        model.gridDisplayMode = .macBook16
        #expect(model.query == "App")
        model.query = ""
        #expect(model.page == 2)
        model.activate(folder)
        model.gridDisplayMode = .fullScreen
        #expect(model.openFolderID == folder.id)
        #expect(model.folderItems.map(\.applicationIDs) == [["app-0"], ["app-1"]])
    }

    @Test func presetTitlesSupportBothInterfaceLanguages() {
        let english = Localizer(language: .english)
        let chinese = Localizer(language: .simplifiedChinese)
        #expect(GridDisplayMode.allCases.map { $0.title(using: english) } == ["Full screen", "14-inch", "16-inch", "24-inch", "27-inch"])
        #expect(GridDisplayMode.allCases.map { $0.title(using: chinese) } == ["全屏", "14 英寸", "16 英寸", "24 英寸", "27 英寸"])
    }
}
