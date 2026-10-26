import AppKit
import SwiftUI

/// 文档预览单独编译，不属于应用 target；示例布局写到脚本提供的临时目录，不碰用户数据。
@main
@MainActor
enum PreviewExport {
    static func main() async throws {
        guard (5...6).contains(CommandLine.arguments.count) else { return }
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        let temporaryDirectory = URL(fileURLWithPath: CommandLine.arguments[2])
        let language = InterfaceLanguage(rawValue: CommandLine.arguments[3]) ?? .english
        let scene = CommandLine.arguments[4]
        let displayMode = CommandLine.arguments.count == 6 ? GridDisplayMode(rawValue: CommandLine.arguments[5]) ?? .macBook14 : .macBook14
        let preferencesName = "LaunchTabletPreview." + UUID().uuidString
        let preferences = UserDefaults(suiteName: preferencesName)!
        defer { preferences.removePersistentDomain(forName: preferencesName) }
        let application = NSApplication.shared
        application.setActivationPolicy(.prohibited)

        let names = ["App Store", "Books", "Calendar", "Clock", "Contacts", "Dictionary", "FaceTime", "Finder", "Freeform", "Home", "Image Capture", "Journal", "Mail", "Maps", "Messages", "Music", "Notes", "Passwords", "Phone", "Photo Booth", "Photos", "Podcasts", "Preview", "QuickTime Player", "Reminders", "Shortcuts", "Stocks", "System Settings", "TextEdit", "TV", "VoiceMemos", "Weather"]
        var applications = names.enumerated().map { index, name in
            let path = name == "Finder" ? "/System/Library/CoreServices/Finder.app" : "/System/Applications/\(name).app"
            return InstalledApplication(id: "preview.app.\(index)", url: URL(fileURLWithPath: path), name: name, searchTerms: name.lowercased(), isAppleApplication: true)
        }
        let folderExamples: [(ApplicationCategory, [String], String)] = [
            (.utilities, ["Developer Tool", "Terminal Tool"], "/System/Applications/Utilities/Terminal.app"),
            (.games, ["Chess"], "/System/Applications/Chess.app"),
            (.other, ["Disk Utility", "Activity Monitor"], "/System/Applications/Utilities/Disk Utility.app"),
            (.edge, ["Sample Docs", "Sample Board"], "/Applications/Microsoft Edge.app"),
            (.chrome, ["Sample Website", "Sample Notes"], "/Applications/Google Chrome.app")
        ]
        var items = applications.map { LauncherItem.application($0.id) }
        for (category, examples, path) in folderExamples {
            let members = examples.enumerated().map { index, name in
                InstalledApplication(id: "preview.folder.\(category.rawValue).\(index)", url: URL(fileURLWithPath: path), name: name, searchTerms: name, category: category)
            }
            applications += members
            items.append(.categoryFolder(category, applicationIDs: members.map(\.id)))
        }
        if scene == "paging" {
            // 用示例应用填满相邻页，直接绘制 30% 位移的真实网格，便于检查动画外扩裁切。
            for index in 0..<40 {
                let example = applications[index % names.count]
                let app = InstalledApplication(id: "preview.extra.\(index)", url: example.url, name: "Sample \(index + 1)", searchTerms: "sample")
                applications.append(app)
                items.insert(.application(app.id), at: items.count - folderExamples.count)
            }
        }
        // 在第一页显示所有文件夹，末页保留少量普通应用以展示分页控件。
        let folders = Array(items.suffix(folderExamples.count))
        items.removeLast(folderExamples.count)
        items.insert(contentsOf: folders, at: 21)
        let repository = LayoutRepository(fileURL: temporaryDirectory.appendingPathComponent("layout.json"))
        try repository.save(LauncherLayout(items: items, organizationVersion: 1, isManuallyArranged: true))
        let snapshot = CatalogSnapshot(applications: applications)
        let model = LauncherModel(repository: repository, preferences: preferences, preferredLanguages: [language.rawValue], scanApplications: { snapshot })
        await model.refreshApplications().value
        model.isPresented = true
        model.language = language
        model.gridDisplayMode = displayMode

        let size: NSSize
        switch scene {
        case "settings": size = NSSize(width: 540, height: 900)
        case "large": size = NSSize(width: 2560, height: 1440)
        case "ultrawide": size = NSSize(width: 3440, height: 1440)
        case "portrait": size = NSSize(width: 1080, height: 1920)
        case "paging": size = NSSize(width: 2560, height: 1440)
        default: size = NSSize(width: 1600, height: 1000)
        }
        let root: AnyView
        if scene == "settings" {
            root = AnyView(LauncherSettings(model: model)
                .environment(\.locale, model.localizer.locale)
                .preferredColorScheme(.dark)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.12, green: 0.13, blue: 0.17)))
        } else if scene == "paging" {
            let metrics = GridMetrics(screenSize: size, displayMode: displayMode)
            let contentWidth = metrics.width - GridMetrics.horizontalGridPadding * 2
            let gridHeight = metrics.height - 142
            root = AnyView(ZStack {
                Color(red: 0.10, green: 0.13, blue: 0.21)
                PagedApplicationGrid(model: model, items: model.rootItems, columns: metrics.columns, rows: metrics.rows, page: 0, iconSize: metrics.iconSize, animationViewportWidth: metrics.pageViewportWidth, scrollOffset: -metrics.pageViewportWidth * 0.3)
                    .frame(width: contentWidth, height: gridHeight)
                // 细框仅用于内部验收，标示静止网格边界，不进入产品界面。
                Rectangle().stroke(.white.opacity(0.2), lineWidth: 1)
                    .frame(width: contentWidth, height: gridHeight).allowsHitTesting(false)
            }.preferredColorScheme(.dark))
        } else {
            if scene == "folder", let folder = model.rootItems.first(where: { $0.folderCategory == .utilities }) { model.activate(folder) }
            root = AnyView(LauncherView(model: model))
        }
        let view = NSHostingView(rootView: root)
        view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw CocoaError(.fileWriteUnknown)
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        // Retina 缓存可能是 2 倍尺寸、高位深；输出按场景尺寸统一为 8 位 PNG，减少仓库体积。
        guard let image = bitmap.cgImage,
              let preview = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: preview) else {
            throw CocoaError(.fileWriteUnknown)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        NSImage(cgImage: image, size: size).draw(in: NSRect(origin: .zero, size: size))
        context.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()
        guard let png = preview.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: output)
        window.close()
        print("Created \(output.path) using isolated sample data; no window was shown.")
    }
}
