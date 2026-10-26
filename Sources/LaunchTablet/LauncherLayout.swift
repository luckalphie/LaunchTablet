import Foundation

/// 类似 Java 的持久化 DTO；只保存业务 ID 和排列，不把图标等系统对象写进 JSON。
struct LauncherItem: Codable, Equatable, Identifiable {
    var id: String
    var applicationIDs: [String]
    var folderName: String?
    /// 非 nil 表示系统生成的分类文件夹；nil 仍代表用户自己创建的文件夹。
    var folderCategory: ApplicationCategory?

    var isFolder: Bool { folderName != nil }

    init(id: String, applicationIDs: [String], folderName: String? = nil, folderCategory: ApplicationCategory? = nil) {
        self.id = id
        self.applicationIDs = applicationIDs
        self.folderName = folderName
        self.folderCategory = folderCategory
    }

    static func application(_ id: String) -> LauncherItem {
        LauncherItem(id: "app:" + id, applicationIDs: [id], folderName: nil, folderCategory: nil)
    }

    static func folder(name: String, applicationIDs: [String]) -> LauncherItem {
        LauncherItem(id: "folder:" + UUID().uuidString, applicationIDs: applicationIDs, folderName: name, folderCategory: nil)
    }

    static func categoryFolder(_ category: ApplicationCategory, applicationIDs: [String]) -> LauncherItem {
        LauncherItem(id: "system-folder:" + category.rawValue, applicationIDs: applicationIDs, folderName: category.rawValue, folderCategory: category)
    }
}

/// Swift 的 struct 是值类型。修改布局时会产生新值，方便 SwiftUI 观察变化，也避免共享可变集合。
struct LauncherLayout: Codable, Equatable {
    var items: [LauncherItem] = []
    var hiddenApplicationIDs: Set<String> = []
    /// 0 是旧布局；首次扫描后迁移为 1，避免每次启动再次重排用户布局。
    var organizationVersion: Int = 0
    var isManuallyArranged = false
    /// 首次观测到的日期按 bundle ID 保存；已有应用更新不会重写日期，卸载后再次安装重新采集。
    var installationDates: [String: Date] = [:]
    /// 独立迁移标记，兼容已保存的手动布局；浏览器网页图标只自动收拢一次，之后仍可自行整理。
    var browserGroupingVersion = 0

    enum CodingKeys: String, CodingKey { case items, hiddenApplicationIDs, organizationVersion, isManuallyArranged, installationDates, browserGroupingVersion }
    init(items: [LauncherItem] = [], hiddenApplicationIDs: Set<String> = [], organizationVersion: Int = 0, isManuallyArranged: Bool = false) {
        self.items = items
        self.hiddenApplicationIDs = hiddenApplicationIDs
        self.organizationVersion = organizationVersion
        self.isManuallyArranged = isManuallyArranged
    }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        // 旧文件也必须包含原有必填字段，防止把损坏的 {} 当作合法空布局覆盖。
        items = try values.decode([LauncherItem].self, forKey: .items)
        hiddenApplicationIDs = try values.decode(Set<String>.self, forKey: .hiddenApplicationIDs)
        organizationVersion = try values.decodeIfPresent(Int.self, forKey: .organizationVersion) ?? 0
        isManuallyArranged = try values.decodeIfPresent(Bool.self, forKey: .isManuallyArranged) ?? false
        installationDates = try values.decodeIfPresent([String: Date].self, forKey: .installationDates) ?? [:]
        browserGroupingVersion = try values.decodeIfPresent(Int.self, forKey: .browserGroupingVersion) ?? 0
    }

    /// 类似 Java 的聚合更新入口：迁移、安装时间记忆和布局对账集中在一起，View 不处理持久化规则。
    mutating func reconcileApplications(_ applications: [InstalledApplication], removeMissing: Bool) {
        let byID = Dictionary(applications.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        if removeMissing {
            installationDates = installationDates.filter { byID[$0.key] != nil }
            hiddenApplicationIDs.formIntersection(byID.keys)
        }
        for application in applications where installationDates[application.id] == nil {
            if let date = application.installationDate { installationDates[application.id] = date }
        }
        if organizationVersion == 0 && removeMissing {
            // 旧版本默认按名称平铺。只有仍为默认顺序的布局自动迁移；用户已建文件夹/隐藏/拖动则保留。
            let knownIDs = items.flatMap(\.applicationIDs).filter { byID[$0] != nil }
            let alphabetical = knownIDs.sorted {
                byID[$0]!.name.localizedStandardCompare(byID[$1]!.name) == .orderedAscending
            }
            isManuallyArranged = isManuallyArranged || items.contains(where: \.isFolder) || !hiddenApplicationIDs.isEmpty || knownIDs != alphabetical
            organizationVersion = 1
        }
        let ordered = byID.values.sorted { InstalledApplication.precedes($0, $1, installationDates: installationDates) }
        if !isManuallyArranged && organizationVersion == 1 && removeMissing {
            organizeDefault(applications: ordered)
        } else {
            let categories = Dictionary(uniqueKeysWithValues: ordered.compactMap { app in app.category.map { (app.id, $0) } })
            reconcile(applicationIDs: ordered.map(\.id), removeMissing: removeMissing, categoryByID: categories)
            if browserGroupingVersion == 0 && removeMissing {
                groupBrowserApplications(categoryByID: categories)
                browserGroupingVersion = 1
            }
        }
    }

    /// 新装应用追加到末尾；卸载应用移除；已有顺序和文件夹保持不变，同一个应用只出现一次。
    mutating func reconcile(applicationIDs: [String], removeMissing: Bool = true, categoryByID: [String: ApplicationCategory] = [:]) {
        var available = Set(applicationIDs)
        // 目录读取失败不代表应用卸载；扫描不完整时保留既有布局，防止一次失败清空用户排列。
        if !removeMissing {
            available.formUnion(items.flatMap(\.applicationIDs))
            available.formUnion(hiddenApplicationIDs)
        }
        hiddenApplicationIDs.formIntersection(available)
        var placed = hiddenApplicationIDs
        items = items.compactMap { original in
            var item = original
            item.applicationIDs = original.applicationIDs.filter { available.contains($0) && placed.insert($0).inserted }
            guard !item.applicationIDs.isEmpty else { return nil }
            return item
        }
        let newIDs = applicationIDs.filter { placed.insert($0).inserted }
        // 已经存在分类文件夹时，新安装应用直接进入对应文件夹，保持“工具/游戏/其它”持续有效。
        var remaining: [String] = []
        for id in newIDs {
            if let category = categoryByID[id], let folder = items.firstIndex(where: { $0.folderCategory == category }) {
                items[folder].applicationIDs.append(id)
            } else if let category = categoryByID[id], category.isBrowserFolder {
                // 手动模式下首次安装某浏览器的网页应用，也建立其专属文件夹，不散落到主网格。
                items.append(.categoryFolder(category, applicationIDs: [id]))
            } else { remaining.append(id) }
        }
        items.append(contentsOf: remaining.map(LauncherItem.application))
    }

    /// 默认布局：常用 Apple 应用在前，分类文件夹出现在首个成员的位置；文件夹内也沿用相同排序。
    /// 仅在自动模式或用户明确选择“恢复默认分类与排序”时调用。
    mutating func organizeDefault(applications: [InstalledApplication]) {
        let ordered = applications.sorted { InstalledApplication.precedes($0, $1, installationDates: installationDates) }
        var result: [LauncherItem] = []
        var folderIndices: [ApplicationCategory: Int] = [:]
        var placed = hiddenApplicationIDs
        for application in ordered where placed.insert(application.id).inserted {
            if let category = application.category {
                if let index = folderIndices[category] {
                    result[index].applicationIDs.append(application.id)
                } else {
                    folderIndices[category] = result.count
                    result.append(.categoryFolder(category, applicationIDs: [application.id]))
                }
            } else {
                result.append(.application(application.id))
            }
        }
        items = result
        organizationVersion = 1
        browserGroupingVersion = 1
        isManuallyArranged = false
    }

    /// 升级时收拢以前平铺或自动分类到“工具”等位置的网页应用，保留自建文件夹及其余图标的相对顺序。
    private mutating func groupBrowserApplications(categoryByID: [String: ApplicationCategory]) {
        for category in [ApplicationCategory.edge, .chrome] {
            let movedIDs = items.filter { !$0.isFolder || ($0.folderCategory != nil && $0.folderCategory != category) }
                .flatMap(\.applicationIDs).filter { categoryByID[$0] == category }
            guard !movedIDs.isEmpty else { continue }
            let moved = Set(movedIDs)
            let targetIndex = items.firstIndex { $0.folderCategory == category }
            guard let anchor = targetIndex ?? items.firstIndex(where: { $0.applicationIDs.contains(where: moved.contains) }) else { continue }
            var folder = targetIndex.map { items[$0] } ?? .categoryFolder(category, applicationIDs: [])
            var placed = Set(folder.applicationIDs)
            folder.applicationIDs += movedIDs.filter { placed.insert($0).inserted }
            var result: [LauncherItem] = []
            for (index, original) in items.enumerated() {
                if index == anchor { result.append(folder) }
                if index == targetIndex { continue }
                var item = original
                item.applicationIDs.removeAll { moved.contains($0) }
                if !item.applicationIDs.isEmpty { result.append(item) }
            }
            items = result
        }
    }

    mutating func move(itemID: String, relativeTo targetID: String, after: Bool) {
        guard itemID != targetID,
              let source = items.firstIndex(where: { $0.id == itemID }),
              items.contains(where: { $0.id == targetID }) else { return }
        let item = items.remove(at: source)
        guard let target = items.firstIndex(where: { $0.id == targetID }) else { return }
        items.insert(item, at: target + (after ? 1 : 0))
    }

    /// 将一个普通应用拖到另一个应用中央时建文件夹，拖到已有文件夹中央时加入该文件夹。
    mutating func group(itemID: String, into targetID: String, folderName: String = "文件夹") {
        guard itemID != targetID,
              let source = items.first(where: { $0.id == itemID }), !source.isFolder,
              let applicationID = source.applicationIDs.first,
              items.contains(where: { $0.id == targetID }) else { return }
        items.removeAll { $0.id == itemID }
        guard let target = items.firstIndex(where: { $0.id == targetID }) else { return }
        if items[target].isFolder {
            items[target].applicationIDs.append(applicationID)
        } else {
            items[target] = .folder(name: folderName, applicationIDs: items[target].applicationIDs + [applicationID])
        }
    }

    mutating func createFolder(itemID: String, name: String = "文件夹") -> String? {
        guard let index = items.firstIndex(where: { $0.id == itemID }), !items[index].isFolder else { return nil }
        items[index] = .folder(name: name, applicationIDs: items[index].applicationIDs)
        return items[index].id
    }

    /// 跨容器移动先在副本上完成，验证通过才提交；类似 Java 中先构造结果再替换聚合，避免失败时丢图标。
    @discardableResult
    mutating func moveApplication(applicationID: String, fromFolderID: String?, toFolderID: String?, relativeTo targetID: String?, after: Bool) -> Bool {
        var candidate = self
        if let folderID = fromFolderID {
            guard let source = candidate.items.firstIndex(where: { $0.id == folderID && $0.isFolder }),
                  candidate.items[source].applicationIDs.contains(applicationID) else { return false }
            candidate.items[source].applicationIDs.removeAll { $0 == applicationID }
            if candidate.items[source].applicationIDs.isEmpty && folderID != toFolderID { candidate.items.remove(at: source) }
        } else {
            guard let source = candidate.items.firstIndex(where: { $0.id == "app:" + applicationID && !$0.isFolder }) else { return false }
            candidate.items.remove(at: source)
        }
        if let folderID = toFolderID {
            guard let destination = candidate.items.firstIndex(where: { $0.id == folderID && $0.isFolder }),
                  !candidate.items[destination].applicationIDs.contains(applicationID) else { return false }
            var index = candidate.items[destination].applicationIDs.count
            if let targetID {
                guard let target = candidate.items[destination].applicationIDs.firstIndex(where: { "app:" + $0 == targetID }) else { return false }
                index = target + (after ? 1 : 0)
            }
            candidate.items[destination].applicationIDs.insert(applicationID, at: index)
        } else {
            var index = candidate.items.count
            if let targetID {
                guard let target = candidate.items.firstIndex(where: { $0.id == targetID }) else { return false }
                index = target + (after ? 1 : 0)
            }
            candidate.items.insert(.application(applicationID), at: index)
        }
        guard candidate != self else { return false }
        self = candidate
        return true
    }

    @discardableResult
    mutating func groupApplication(applicationID: String, fromFolderID: String?, into targetID: String, folderName: String = "文件夹") -> Bool {
        guard let target = items.first(where: { $0.id == targetID }), targetID != "app:" + applicationID else { return false }
        if target.isFolder {
            return moveApplication(applicationID: applicationID, fromFolderID: fromFolderID, toFolderID: targetID, relativeTo: nil, after: true)
        }
        var candidate = self
        if let fromFolderID {
            guard candidate.moveApplication(applicationID: applicationID, fromFolderID: fromFolderID, toFolderID: nil, relativeTo: targetID, after: true) else { return false }
        }
        candidate.group(itemID: "app:" + applicationID, into: targetID, folderName: folderName)
        guard candidate != self else { return false }
        self = candidate
        return true
    }

    mutating func renameFolder(id: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = items.firstIndex(where: { $0.id == id && $0.isFolder }) else { return }
        items[index].folderName = String(trimmed.prefix(40))
    }

    mutating func dissolveFolder(id: String) {
        guard let index = items.firstIndex(where: { $0.id == id && $0.isFolder }) else { return }
        let applications = items.remove(at: index).applicationIDs.map(LauncherItem.application)
        items.insert(contentsOf: applications, at: index)
    }

    mutating func removeFromFolder(applicationID: String, folderID: String) {
        guard let index = items.firstIndex(where: { $0.id == folderID && $0.isFolder }),
              items[index].applicationIDs.contains(applicationID) else { return }
        items[index].applicationIDs.removeAll { $0 == applicationID }
        items.insert(.application(applicationID), at: index + 1)
        if items[index].applicationIDs.isEmpty { items.remove(at: index) }
    }

    mutating func hide(applicationID: String) {
        hiddenApplicationIDs.insert(applicationID)
        items = items.compactMap { original in
            var item = original
            item.applicationIDs.removeAll { $0 == applicationID }
            return item.applicationIDs.isEmpty ? nil : item
        }
    }
}

/// 类似一个很小的 Repository。原子写入保证退出或断电时不会只留下半份 JSON。
struct LayoutRepository {
    let fileURL: URL
    var legacyFileURL: URL? = nil

    static var standard: LayoutRepository {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return LayoutRepository(fileURL: root.appendingPathComponent("LaunchTablet/layout.json"), legacyFileURL: root.appendingPathComponent(AppIdentity.legacyDataDirectory + "/layout.json"))
    }

    func load() throws -> LauncherLayout {
        // 只有新版文件不存在才读取旧布局；新版损坏时不能静默回退旧数据。
        // 下一次保存写入新路径，旧文件保持原样，避免改名迁移失败时破坏原有排列。
        let source: URL
        if FileManager.default.fileExists(atPath: fileURL.path) { source = fileURL }
        else if let legacyFileURL, FileManager.default.fileExists(atPath: legacyFileURL.path) { source = legacyFileURL }
        else { return LauncherLayout() }
        return try JSONDecoder().decode(LauncherLayout.self, from: Data(contentsOf: source))
    }

    func save(_ layout: LauncherLayout) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(layout).write(to: fileURL, options: .atomic)
    }
}
