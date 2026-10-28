import AppKit
import Combine
import ImageIO

/// 类似 Java 中的页面 Service + ViewModel。
/// @MainActor 表示所有可见状态在主线程修改；@Published 变化后 SwiftUI 会自动刷新界面，无须手动 repaint。
@MainActor
final class LauncherModel: ObservableObject {
    @Published private(set) var applications: [InstalledApplication] = []
    @Published private(set) var layout: LauncherLayout
    @Published var query = "" {
        didSet {
            guard query != oldValue else { return }
            if oldValue.isEmpty && !query.isEmpty { browsePage = page; page = 0 }
            if !oldValue.isEmpty && query.isEmpty { page = browsePage }
            selectedItemID = nil
            keyboardNavigationActive = false
            clampPages()
        }
    }
    @Published private(set) var page = 0
    @Published private(set) var folderPage = 0
    @Published private(set) var openFolderID: String?
    @Published private(set) var selectedItemID: String?
    @Published var isPresented = false
    @Published var presentationID = 0
    @Published var isSettingsPresented = false
    @Published var isHelpPresented = false
    @Published var isRenamingFolder = false
    enum Failure {
        case invalidLayout
        case shortcutUnavailable(ShortcutPreset)
        case launchFailed(name: String, reason: String)
        case saveFailed(String)
    }
    @Published var failure: Failure?
    @Published var language: InterfaceLanguage {
        didSet {
            guard language != oldValue else { return }
            preferences.set(language.rawValue, forKey: "interfaceLanguage")
            languageChanged?()
        }
    }
    @Published var gridDisplayMode: GridDisplayMode {
        didSet {
            guard gridDisplayMode != oldValue else { return }
            preferences.set(gridDisplayMode.rawValue, forKey: "gridDisplayMode")
        }
    }
    @Published private(set) var isLoading = true
    @Published private(set) var isLaunching = false
    @Published private(set) var hasCatalogWarning = false
    @Published private(set) var wallpaper: NSImage?
    @Published private(set) var currentDisplayName = ""
    @Published private(set) var scrollOffset: CGFloat = 0
    @Published private(set) var isScrolling = false
    @Published private(set) var dropTargetID: String?
    @Published private(set) var isGroupingDrop = false
    @Published var shortcut: ShortcutPreset {
        didSet {
            preferences.set(shortcut.rawValue, forKey: "shortcut")
            shortcutChanged?(shortcut)
        }
    }

    let icons = ApplicationIcons()
    var dismissRequested: (() -> Void)?
    var shortcutChanged: ((ShortcutPreset) -> Void)?
    var languageChanged: (() -> Void)?
    @Published private(set) var draggedItemID: String?
    @Published private(set) var dropAfter = false
    private var groupingCandidate = false
    private var targetHoverTask: Task<Void, Never>?
    private var folderExitTask: Task<Void, Never>?
    private var dragSourceFolderID: String?
    private var keyboardNavigationActive = false
    private var browsePage = 0
    private var columns = 7
    private var rows = 5
    private var scrollDistance: CGFloat = 0
    private enum ScrollAxis { case horizontal, vertical }
    private var scrollAxis: ScrollAxis?
    private var gestureDeltaX: CGFloat = 0
    private var gestureDeltaY: CGFloat = 0
    private var scrollDidTurn = false
    private var lastScrollEvent = Date.distantPast
    private var lastWheelTurn = Date.distantPast
    private var refreshTask: Task<Void, Never>?
    private var refreshRequested = false
    private var refreshDebounce: Task<Void, Never>?
    private var pageHoverTask: Task<Void, Never>?
    private let repository: LayoutRepository
    private let preferences: UserDefaults
    private let preferredLanguages: [String]
    private let scanApplications: @Sendable () -> CatalogSnapshot
    private var applicationsByID: [String: InstalledApplication] = [:]
    private var mayPersist = true
    private var wallpaperURL: URL?
    private var wallpaperTask: Task<Void, Never>?

    init(repository: LayoutRepository = .standard, preferences: UserDefaults = .standard, preferredLanguages: [String] = Locale.preferredLanguages, scanApplications: @escaping @Sendable () -> CatalogSnapshot = { ApplicationCatalog.scan() }) {
        self.repository = repository
        self.preferences = preferences
        self.preferredLanguages = preferredLanguages
        if Bundle.main.bundleIdentifier == AppIdentity.bundleIdentifier {
            AppIdentity.migrateLegacyPreferences(to: preferences, legacyValues: preferences.persistentDomain(forName: AppIdentity.legacyBundleIdentifier) ?? [:])
        }
        self.language = InterfaceLanguage(rawValue: preferences.string(forKey: "interfaceLanguage") ?? "") ?? .system
        // 未配置和未知配置均保留旧版的 14 寸显示范围；仅保存偏好，不重写用户排列。
        self.gridDisplayMode = GridDisplayMode(rawValue: preferences.string(forKey: "gridDisplayMode") ?? "") ?? .macBook14
        self.scanApplications = scanApplications
        self.shortcut = ShortcutPreset(rawValue: preferences.string(forKey: "shortcut") ?? "") ?? .controlOptionSpace
        do { self.layout = try repository.load() }
        catch {
            self.layout = LauncherLayout()
            // 保留无法解析的文件，不能用空布局覆盖用户原来的排列。
            self.mayPersist = false
            self.failure = .invalidLayout
        }
    }

    var localizer: Localizer { Localizer(language: language, preferredLanguages: preferredLanguages) }
    func text(_ key: TextKey, _ arguments: CVarArg...) -> String { localizer.text(key, arguments: arguments) }
    var shortcutLabel: String { shortcut.label(using: localizer) }
    var catalogWarning: String? { hasCatalogWarning ? text(.inaccessibleApplications) : nil }
    var errorText: String? {
        switch failure {
        case .invalidLayout: return text(.invalidLayout)
        case .shortcutUnavailable(let shortcut): return text(.shortcutUnavailable, shortcut.label(using: localizer))
        case .launchFailed(let name, let reason): return text(.launchFailed, name, reason)
        case .saveFailed(let reason): return text(.saveFailed, reason)
        case nil: return nil
        }
    }

    var rootItems: [LauncherItem] {
        guard !query.isEmpty else { return layout.items.filter { item in item.applicationIDs.contains { application(id: $0) != nil } } }
        return applications.filter { !layout.hiddenApplicationIDs.contains($0.id) && $0.matches(query) }.map { .application($0.id) }
    }

    var openFolder: LauncherItem? { layout.items.first { $0.id == openFolderID && $0.isFolder } }
    var folderItems: [LauncherItem] { (openFolder?.applicationIDs ?? []).filter { application(id: $0) != nil }.map(LauncherItem.application) }
    var activeItems: [LauncherItem] { openFolderID == nil ? rootItems : folderItems }
    var capacity: Int { columns * rows }
    var activeCapacity: Int { openFolderID == nil ? capacity : 12 }
    var activeColumns: Int { openFolderID == nil ? columns : 4 }
    var activePage: Int { openFolderID == nil ? page : folderPage }
    var rootPageCount: Int { Self.pageCount(itemCount: rootItems.count, capacity: capacity) }
    var folderPageCount: Int { Self.pageCount(itemCount: folderItems.count, capacity: 12) }
    var hiddenApplications: [InstalledApplication] { applications.filter { layout.hiddenApplicationIDs.contains($0.id) } }

    static func pageCount(itemCount: Int, capacity: Int) -> Int {
        let size = max(1, capacity)
        return max(1, (itemCount + size - 1) / size)
    }

    func application(for item: LauncherItem) -> InstalledApplication? {
        guard let id = item.applicationIDs.first else { return nil }
        return application(id: id)
    }

    func application(id: String) -> InstalledApplication? { applicationsByID[id] }
    func title(for item: LauncherItem) -> String {
        // 中文 rawValue 是旧 JSON 的持久化协议，仅在展示层翻译；用户重命名过的文件夹不翻译。
        if let category = item.folderCategory, item.folderName == category.rawValue { return category.title(using: localizer) }
        return item.folderName ?? application(for: item)?.name ?? text(.application)
    }

    func updateGrid(columns: Int, rows: Int) {
        self.columns = columns
        self.rows = rows
        clampPages()
    }

    func updateWallpaper(for screen: NSScreen) {
        currentDisplayName = screen.localizedName
        let url = NSWorkspace.shared.desktopImageURL(for: screen)
        guard url != wallpaperURL else { return }
        wallpaperURL = url
        wallpaperTask?.cancel()
        wallpaper = nil
        guard let url else { return }
        wallpaperTask = Task { [weak self] in
            // 超大屏也只需要低分辨率模糊背景，避免把原始 5K/8K 壁纸完整解码到 UI 线程。
            let image = await Task.detached(priority: .utility) {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil as CGImage? }
                let options = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                               kCGImageSourceThumbnailMaxPixelSize: 1600,
                               kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options)
            }.value
            guard !Task.isCancelled, let self, let image else { return }
            self.wallpaper = NSImage(cgImage: image, size: .zero)
        }
    }

    func prepareToShow() {
        query = ""
        closeFolder()
        selectedItemID = nil
        keyboardNavigationActive = false
        isSettingsPresented = false
        isHelpPresented = false
        endDragging()
        resetScroll()
        isPresented = true
        presentationID += 1
        refreshApplications()
    }

    func prepareToHide() {
        isPresented = false
        isSettingsPresented = false
        isHelpPresented = false
        endDragging()
        resetScroll()
    }

    /// Task.detached 类似提交到 Java 后台线程池；await 后回到 MainActor 更新 UI 状态。
    @discardableResult
    func refreshApplications() -> Task<Void, Never> {
        if let refreshTask {
            // 扫描期间发生安装或呼出时，当前快照可能已经过期；完成后再扫描一次。
            refreshRequested = true
            return refreshTask
        }
        let scan = scanApplications
        let task = Task { [weak self] in
            while true {
                let snapshot = await Task.detached(priority: .userInitiated, operation: scan).value
                guard let self else { return }
                var discovered = snapshot.applications
                if !snapshot.inaccessibleRoots.isEmpty {
                    let found = Set(discovered.map(\.id))
                    discovered += self.applications.filter { !found.contains($0.id) }
                }
                self.hasCatalogWarning = !snapshot.inaccessibleRoots.isEmpty
                self.applicationsByID = Dictionary(discovered.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                self.applications = discovered
                let oldLayout = self.layout
                self.layout.reconcileApplications(discovered, removeMissing: snapshot.inaccessibleRoots.isEmpty)
                if oldLayout != self.layout { self.persistLayout(markAsManual: false) }
                self.isLoading = false
                self.clampPages()
                if self.refreshRequested {
                    self.refreshRequested = false
                    continue
                }
                self.refreshTask = nil
                break
            }
        }
        refreshTask = task
        return task
    }

    func scheduleRefresh() {
        refreshDebounce?.cancel()
        refreshDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            self?.icons.clear()
            self?.refreshApplications()
        }
    }

    func setPage(_ newPage: Int) {
        let count = openFolderID == nil ? rootPageCount : folderPageCount
        let target = min(max(newPage, 0), count - 1)
        if openFolderID == nil {
            page = target
            if query.isEmpty { browsePage = target }
        } else { folderPage = target }
        selectedItemID = nil
        keyboardNavigationActive = false
    }

    func turnPage(by offset: Int) { setPage(activePage + offset) }

    /// 本地事件监视器在文本框处理按键前调用此方法，因此 Esc 不受 SwiftUI 焦点变化影响。
    /// 返回 true 表示事件已经处理，不能再交给文本框，否则会重复执行或发出系统提示音。
    func handleKey(_ event: NSEvent) -> Bool {
        if event.keyCode == 53 {
            handleEscape()
            return true
        }
        guard !isRenamingFolder, !isSettingsPresented, !isHelpPresented else { return false }
        guard event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        switch event.keyCode {
        case 36, 76:
            if let selected = activeItems.first(where: { $0.id == selectedItemID }) { activate(selected) }
            else if !query.isEmpty, let first = activeItems.first { activate(first) }
            else { return false }
            return true
        case 125: navigate(by: activeColumns); return true
        case 126: navigate(by: -activeColumns); return true
        case 123, 124:
            // 搜索输入过程中保留左右键的光标语义；按上下键进入网格后再用左右键选应用。
            if !query.isEmpty && !keyboardNavigationActive { return false }
            navigate(by: event.keyCode == 123 ? -1 : 1)
            return true
        case 116: turnPage(by: -1); return true
        case 121: turnPage(by: 1); return true
        default: return false
        }
    }

    func handleEscape() {
        if failure != nil { failure = nil }
        else if isSettingsPresented { isSettingsPresented = false }
        else if isHelpPresented { isHelpPresented = false }
        else if openFolderID != nil { closeFolder() }
        else if !query.isEmpty { query = "" }
        else { dismissRequested?() }
    }

    private func navigate(by offset: Int) {
        let items = activeItems
        guard !items.isEmpty else { return }
        let next: Int
        if let current = items.firstIndex(where: { $0.id == selectedItemID }) {
            next = min(max(current + offset, 0), items.count - 1)
        } else { next = min(activePage * activeCapacity, items.count - 1) }
        setPage(next / activeCapacity)
        selectedItemID = items[next].id
        keyboardNavigationActive = true
    }

    /// 触控板一轮手势最多翻一页，忽略后续惯性，避免轻扫一下跳过好几页。
    /// 精确滚动也可能来自平滑滚轮；两种轴向都映射为横向分页，不能用精确标记判断设备类型。
    func handleScroll(_ event: NSEvent) -> Bool {
        guard !isSettingsPresented, !isHelpPresented, !isRenamingFolder else { return false }
        let now = Date()
        if !event.hasPreciseScrollingDeltas {
            let delta = abs(event.scrollingDeltaX) > 0 ? event.scrollingDeltaX : event.scrollingDeltaY
            guard abs(delta) > 0 else { return false }
            if now.timeIntervalSince(lastWheelTurn) > 0.32 {
                turnPage(by: delta < 0 ? 1 : -1)
                lastWheelTurn = now
            }
            return true
        }
        if !event.momentumPhase.isEmpty { return true }
        if event.phase.contains(.began) || now.timeIntervalSince(lastScrollEvent) > 0.3 {
            scrollDistance = 0
            scrollDidTurn = false
            scrollAxis = nil
            gestureDeltaX = 0
            gestureDeltaY = 0
        }
        lastScrollEvent = now
        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            resetScroll()
            return true
        }
        guard !scrollDidTurn else { return true }
        gestureDeltaX += event.scrollingDeltaX
        gestureDeltaY += event.scrollingDeltaY
        // 累计到少量位移再锁定主要轴向，过滤手势刚开始的微小斜向抖动。
        if scrollAxis == nil, max(abs(gestureDeltaX), abs(gestureDeltaY)) >= 6 {
            scrollAxis = abs(gestureDeltaX) >= abs(gestureDeltaY) ? .horizontal : .vertical
        }
        guard let scrollAxis else { return true }
        isScrolling = true
        scrollDistance = scrollAxis == .horizontal ? gestureDeltaX : gestureDeltaY
        let atBoundary = (activePage == 0 && scrollDistance > 0)
            || (activePage == (openFolderID == nil ? rootPageCount : folderPageCount) - 1 && scrollDistance < 0)
        scrollOffset = scrollDistance * (atBoundary ? 0.2 : 0.8)
        if abs(scrollDistance) >= 55 {
            turnPage(by: scrollDistance < 0 ? 1 : -1)
            scrollDidTurn = true
            scrollOffset = 0
            isScrolling = false
        }
        return true
    }

    private func resetScroll() {
        scrollDistance = 0
        scrollAxis = nil
        gestureDeltaX = 0
        gestureDeltaY = 0
        scrollOffset = 0
        isScrolling = false
    }

    func activate(_ item: LauncherItem) {
        if item.isFolder {
            openFolderID = item.id
            folderPage = 0
            selectedItemID = nil
            keyboardNavigationActive = false
            resetScroll()
            return
        }
        guard !isLaunching, let application = application(for: item) else { return }
        isLaunching = true
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: application.url, configuration: configuration) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isLaunching = false
                if let error { self.failure = .launchFailed(name: application.name, reason: error.localizedDescription) }
                else { self.dismissRequested?() }
            }
        }
    }

    func closeFolder() {
        openFolderID = nil
        isRenamingFolder = false
        selectedItemID = nil
        folderPage = 0
        resetScroll()
    }

    func renameFolder(_ name: String, id: String? = nil) {
        guard let id = id ?? openFolderID else { return }
        let previous = layout
        layout.renameFolder(id: id, name: name)
        guard layout != previous else { return }
        persistLayout()
    }

    func createFolder(for item: LauncherItem) {
        if let id = layout.createFolder(itemID: item.id, name: text(.folder)) {
            persistLayout()
            if let folder = layout.items.first(where: { $0.id == id }) { activate(folder) }
        }
    }

    func dissolveFolder(_ item: LauncherItem) {
        if openFolderID == item.id { closeFolder() }
        layout.dissolveFolder(id: item.id)
        persistLayout()
        clampPages()
    }

    func removeFromFolder(_ item: LauncherItem) {
        guard let folderID = openFolderID, let appID = item.applicationIDs.first else { return }
        layout.removeFromFolder(applicationID: appID, folderID: folderID)
        if openFolder == nil { closeFolder() }
        persistLayout()
        clampPages()
    }

    func hideApplication(_ item: LauncherItem) {
        guard let id = item.applicationIDs.first else { return }
        layout.hide(applicationID: id)
        if openFolderID != nil && openFolder == nil { closeFolder() }
        persistLayout()
        clampPages()
    }

    func restoreApplication(id: String) {
        layout.hiddenApplicationIDs.remove(id)
        layout.reconcileApplications(applications, removeMissing: catalogWarning == nil)
        persistLayout()
    }

    func restoreDefaultOrganization() {
        guard !isLoading, catalogWarning == nil else { return }
        closeFolder()
        query = ""
        layout.organizeDefault(applications: applications)
        setPage(0)
        persistLayout(markAsManual: false)
    }

    func reveal(_ item: LauncherItem) {
        if let application = application(for: item) {
            NSWorkspace.shared.activateFileViewerSelecting([application.url])
            dismissRequested?()
        }
    }

    func beginDragging(_ item: LauncherItem) {
        endDragging()
        guard query.isEmpty, activeItems.contains(where: { $0.id == item.id }) else { return }
        draggedItemID = item.id
        dragSourceFolderID = openFolderID
    }

    /// 中央悬停 450ms 才合并普通图标；文件夹可直接接收，继续悬停 750ms 自动展开。
    func updateDropTarget(_ id: String?, grouping: Bool, after: Bool = false) {
        endFolderExitHover()
        dropAfter = after
        guard dropTargetID != id || groupingCandidate != grouping else { return }
        targetHoverTask?.cancel()
        dropTargetID = id
        groupingCandidate = grouping
        isGroupingDrop = false
        guard draggedItemID != nil, let id, grouping,
              let target = layout.items.first(where: { $0.id == id }) else { return }
        isGroupingDrop = target.isFolder
        targetHoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(target.isFolder ? 750 : 450))
            guard !Task.isCancelled, let self, self.draggedItemID != nil, self.dropTargetID == id else { return }
            self.isGroupingDrop = true
            if target.isFolder {
                self.activate(target)
                self.updateDropTarget(nil, grouping: false)
            }
        }
    }

    private var draggedApplicationID: String? {
        guard let sourceID = draggedItemID else { return nil }
        if let folderID = dragSourceFolderID {
            return layout.items.first(where: { $0.id == folderID })?.applicationIDs.first { "app:" + $0 == sourceID }
        }
        return layout.items.first(where: { $0.id == sourceID && !$0.isFolder })?.applicationIDs.first
    }

    func performDrop(onto target: LauncherItem, grouping: Bool, after: Bool) -> Bool {
        defer { endDragging() }
        guard let sourceID = draggedItemID, sourceID != target.id else { return false }
        let previous = layout
        if let applicationID = draggedApplicationID {
            if openFolderID == nil && grouping {
                layout.groupApplication(applicationID: applicationID, fromFolderID: dragSourceFolderID, into: target.id, folderName: text(.folder))
            } else {
                layout.moveApplication(applicationID: applicationID, fromFolderID: dragSourceFolderID, toFolderID: openFolderID, relativeTo: target.id, after: after)
            }
        } else if dragSourceFolderID == nil && openFolderID == nil && !grouping {
            layout.move(itemID: sourceID, relativeTo: target.id, after: after)
        }
        return finishLayoutDrop(previous: previous)
    }

    func dropIntoEmptySlot() -> Bool {
        defer { endDragging() }
        let previous = layout
        if let applicationID = draggedApplicationID {
            layout.moveApplication(applicationID: applicationID, fromFolderID: dragSourceFolderID, toFolderID: openFolderID, relativeTo: nil, after: true)
        } else if openFolderID == nil, dragSourceFolderID == nil,
                  let source = layout.items.firstIndex(where: { $0.id == draggedItemID }) {
            layout.items.append(layout.items.remove(at: source))
        }
        return finishLayoutDrop(previous: previous)
    }

    private func finishLayoutDrop(previous: LauncherLayout) -> Bool {
        guard layout != previous else { return false }
        if openFolderID != nil && openFolder == nil { closeFolder() }
        persistLayout()
        clampPages()
        return true
    }

    func canGroup(onto target: LauncherItem) -> Bool {
        openFolderID == nil && draggedApplicationID != nil && draggedItemID != target.id
    }

    /// 文件夹外停留后返回主网格，保留拖拽来源，直到成功投放才真正修改布局。
    func beginFolderExitHover() {
        guard draggedItemID != nil, openFolderID != nil, folderExitTask == nil else { return }
        updateDropTarget(nil, grouping: false)
        endPageHover()
        folderExitTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.closeFolder()
            self.folderExitTask = nil
        }
    }

    func endFolderExitHover() { folderExitTask?.cancel(); folderExitTask = nil }

    func beginPageHover(direction: Int) {
        updateDropTarget(nil, grouping: false)
        pageHoverTask?.cancel()
        guard draggedItemID != nil else { return }
        pageHoverTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled, let self else { return }
                self.turnPage(by: direction)
            }
        }
    }

    func endPageHover() { pageHoverTask?.cancel(); pageHoverTask = nil }
    func endDragging() {
        targetHoverTask?.cancel()
        targetHoverTask = nil
        endFolderExitHover()
        draggedItemID = nil
        dragSourceFolderID = nil
        dropTargetID = nil
        isGroupingDrop = false
        groupingCandidate = false
        dropAfter = false
        endPageHover()
    }

    private func clampPages() {
        page = min(max(page, 0), rootPageCount - 1)
        folderPage = min(max(folderPage, 0), folderPageCount - 1)
        if query.isEmpty { browsePage = page }
    }

    private func persistLayout(markAsManual: Bool = true) {
        if markAsManual { layout.isManuallyArranged = true }
        guard mayPersist else { return }
        do { try repository.save(layout) }
        catch { failure = .saveFailed(error.localizedDescription) }
    }
}
