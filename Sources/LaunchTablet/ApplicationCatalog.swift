import AppKit
import Security

/// 可跨线程传递的应用元数据。图标 NSImage 不放在这里，避免后台扫描携带 UI 对象。
struct InstalledApplication: Identifiable, Sendable {
    let id: String
    let url: URL
    let name: String
    let searchTerms: String
    /// Apple 自带应用优先显示；安装日期用于第三方应用的默认顺序。
    let isAppleApplication: Bool
    let installationDate: Date?
    let category: ApplicationCategory?

    init(id: String, url: URL, name: String, searchTerms: String, isAppleApplication: Bool = false, installationDate: Date? = nil, category: ApplicationCategory? = nil) {
        self.id = id
        self.url = url
        self.name = name
        self.searchTerms = searchTerms
        self.isAppleApplication = isAppleApplication
        self.installationDate = installationDate
        self.category = category
    }

    func matches(_ query: String) -> Bool {
        let words = Self.normalize(query).split(whereSeparator: { $0.isWhitespace })
        return words.allSatisfy { searchTerms.contains($0) }
    }

    static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).lowercased()
    }

    static func precedes(_ left: Self, _ right: Self, installationDates: [String: Date] = [:]) -> Bool {
        if left.isAppleApplication != right.isAppleApplication { return left.isAppleApplication }
        if !left.isAppleApplication {
            // 日期缺失排在已知日期后；ID 兜底使同名同日期应用也有稳定顺序。
            let leftDate = installationDates[left.id] ?? left.installationDate ?? .distantFuture
            let rightDate = installationDates[right.id] ?? right.installationDate ?? .distantFuture
            if leftDate != rightDate { return leftDate < rightDate }
        }
        let result = left.name.localizedStandardCompare(right.name)
        return result == .orderedSame ? left.id < right.id : result == .orderedAscending
    }
}

/// 类似 Java 枚举。分类依据应用自己声明的标准类别；未声明类别的普通应用直接放在主网格。
enum ApplicationCategory: String, Codable, Sendable {
    case utilities = "工具"
    case games = "游戏"
    case other = "其它"
    case edge = "Edge"
    case chrome = "Chrome"

    func title(using localizer: Localizer) -> String {
        switch self {
        case .utilities: return localizer.text(.utilitiesCategory)
        case .games: return localizer.text(.gamesCategory)
        case .other: return localizer.text(.otherCategory)
        case .edge, .chrome: return rawValue
        }
    }

    var isBrowserFolder: Bool { self == .edge || self == .chrome }

    static func browserFolder(in path: String) -> Self? {
        // 使用来源目录而不是 bundle ID 前缀识别，避免把 Edge/Chrome 浏览器本体也归进网页应用文件夹。
        let parents = URL(fileURLWithPath: path).deletingLastPathComponent().pathComponents.reversed()
        for component in parents {
            switch component.lowercased() {
            case "edge apps.localized", "edge apps": return .edge
            case "chrome apps.localized", "chrome apps": return .chrome
            default: continue
            }
        }
        return nil
    }

    static func from(bundleCategory: String?, path: String, isApple: Bool, bundleID: String) -> Self? {
        if let browser = browserFolder(in: path) { return browser }
        let value = bundleCategory?.lowercased() ?? ""
        // App Store 游戏类别既有 games，也有 board-games、role-playing-games 等子类别。
        if value.hasPrefix("public.app-category."), value == "public.app-category.games" || value.hasSuffix("-games") {
            return .games
        }
        if isApple {
            // 系统自带 Utilities 放进原版常见的“其它”，App Store、设置、快捷指令等常用应用留在主网格。
            return path.contains("/Utilities/") || bundleID == "com.apple.helpviewer" ? .other : nil
        }
        if value == "public.app-category.utilities" || value == "public.app-category.developer-tools" || path.contains("/Utilities/") {
            return .utilities
        }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent.lowercased()
        if ["工具", "utilities", "tools"].contains(parent) { return .utilities }
        if ["游戏", "games"].contains(parent) { return .games }
        if ["其它", "其他", "other"].contains(parent) { return .other }
        return nil
    }
}

struct CatalogSnapshot: Sendable {
    let applications: [InstalledApplication]
    var inaccessibleRoots: [String] = []
}

enum ApplicationCatalog {
    // 同一 bundle ID 多处安装时优先使用用户目录，再使用公共目录；不重复展示同一应用。
    static let roots = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/System/Applications")
    ]

    /// 文件遍历和 Bundle 读取会阻塞线程，调用方必须放到后台任务中；不需要额外系统权限。
    static func scan() -> CatalogSnapshot {
        var applications: [String: InstalledApplication] = [:]
        var inaccessibleRoots = Set<String>()
        let keys: [URLResourceKey] = [.localizedNameKey, .isDirectoryKey]

        func addApplication(at rawURL: URL) {
            let url = rawURL.resolvingSymlinksInPath().standardizedFileURL
            guard let bundle = Bundle(url: url) else { return }
            let info = bundle.infoDictionary ?? [:]
            // 隐藏菜单栏助手、后台进程和启动器自身，避免把辅助程序当成可启动应用。
            guard !boolean(info["LSUIElement"]), !boolean(info["LSBackgroundOnly"]),
                  !AppIdentity.isLauncher(bundleIdentifier: bundle.bundleIdentifier) else { return }
            let id = bundle.bundleIdentifier ?? url.path
            guard applications[id] == nil else { return }

            let fileName = (try? url.resourceValues(forKeys: [.localizedNameKey]).localizedName) ?? url.lastPathComponent
            let localized = bundle.localizedInfoDictionary
            let displayName = localized?["CFBundleDisplayName"] as? String
                ?? localized?["CFBundleName"] as? String
                ?? fileName
            let name = displayName.hasSuffix(".app") ? String(displayName.dropLast(4)) : displayName
            let latin = name.applyingTransform(.toLatin, reverse: false) ?? name
            let initials = latin.split(whereSeparator: { $0.isWhitespace }).compactMap(\.first).map(String.init).joined()
            let terms = [name, url.deletingPathExtension().lastPathComponent, info["CFBundleName"] as? String ?? "", latin, latin.replacingOccurrences(of: " ", with: ""), initials]
            let resourceValues = try? url.resourceValues(forKeys: [.addedToDirectoryDateKey, .creationDateKey])
            // 优先使用加入当前应用目录的日期；旧应用可能没有此属性，再使用 bundle 创建时间。
            // 更新应用会替换 bundle，Layout 首次记录后按 ID 保留日期，避免更新导致顺序跳动。
            let installationDate = resourceValues?.addedToDirectoryDate ?? resourceValues?.creationDate
            let isApple = isAppleApplication(at: url, bundleID: id)
            // 原路径保留浏览器目录来源，符号链接解析后仍可正确归组。
            let category = ApplicationCategory.browserFolder(in: rawURL.path)
                ?? ApplicationCategory.from(bundleCategory: info["LSApplicationCategoryType"] as? String, path: url.path, isApple: isApple, bundleID: id)
            applications[id] = InstalledApplication(id: id, url: url, name: name, searchTerms: InstalledApplication.normalize(terms.joined(separator: " ")), isAppleApplication: isApple, installationDate: installationDate, category: category)
        }

        for root in roots {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            guard let iterator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in
                inaccessibleRoots.insert(root.path)
                return true
            }) else { inaccessibleRoots.insert(root.path); continue }
            for case let url as URL in iterator {
                if url.pathExtension.lowercased() == "app" {
                    addApplication(at: url)
                    iterator.skipDescendants()
                }
            }
        }
        addApplication(at: URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app"))
        let sorted = applications.values.sorted { InstalledApplication.precedes($0, $1) }
        return CatalogSnapshot(applications: sorted, inaccessibleRoots: inaccessibleRoots.sorted())
    }

    private static func isAppleApplication(at url: URL, bundleID: String) -> Bool {
        if url.path.hasPrefix("/System/Applications/") || url.path.hasPrefix("/System/Library/CoreServices/") { return true }
        guard bundleID.hasPrefix("com.apple.") else { return false }
        // /Applications 下也有 Apple 下载的软件；核对 Apple 签名，避免仅靠可自定义的 bundle ID 判断。
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let flags = SecCSFlags(rawValue: 0)
        guard SecStaticCodeCreateWithPath(url as CFURL, flags, &code) == errSecSuccess,
              SecRequirementCreateWithString("anchor apple" as CFString, flags, &requirement) == errSecSuccess,
              let code, let requirement else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSBasicValidateOnly), requirement) == errSecSuccess
    }

    private static func boolean(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return ["true", "yes", "1"].contains(string.lowercased()) }
        return false
    }
}

/// AppKit 图标只能在主线程读取，NSCache 会在系统内存紧张时自动释放缓存。
@MainActor
final class ApplicationIcons {
    private let cache = NSCache<NSString, NSImage>()

    func image(for application: InstalledApplication) -> NSImage {
        let key = application.url.path as NSString
        if let image = cache.object(forKey: key) { return image }
        let image = NSWorkspace.shared.icon(forFile: application.url.path)
        cache.setObject(image, forKey: key)
        return image
    }

    func clear() { cache.removeAllObjects() }
}

/// 监听安装目录变化，而不是每隔几秒全量轮询。目录变化由系统事件通知，扫描由 Model 做防抖。
final class ApplicationDirectoryWatcher {
    private var sources: [DispatchSourceFileSystemObject] = []

    init(didChange: @escaping () -> Void) {
        for root in ApplicationCatalog.roots {
            let descriptor = open(root.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler(handler: didChange)
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
    }

    deinit { sources.forEach { $0.cancel() } }
}
