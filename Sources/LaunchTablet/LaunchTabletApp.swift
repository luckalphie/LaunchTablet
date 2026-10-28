import AppKit
import SwiftUI
import os

/// AppKit 负责程序生命周期、系统事件和窗口；SwiftUI 负责窗口内部的声明式界面。
/// 可类比 Java 桌面程序的 main + Application：主线程进入 app.run() 后一直处理系统事件。
@main
@MainActor
enum LaunchTabletApp {
    static func main() {
        let application = NSApplication.shared
        if CommandLine.arguments.dropFirst() == ["--check-localizations"] {
            // 分发包的无窗口自检入口：同时覆盖资源是否随包、运行时路径和完整键集。
            for language in [InterfaceLanguage.english, .simplifiedChinese] {
                let localizer = Localizer(language: language)
                // 直接检查各语言的原始键集，避免英文兜底掩盖中文资源缺失。
                guard let directory = Localizer.resourceDirectory(for: language),
                      let data = try? Data(contentsOf: directory.appendingPathComponent("Localizable.strings")),
                      let strings = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: String],
                      Set(strings.keys) == Set(TextKey.allCases.map(\.rawValue)),
                      TextKey.allCases.allSatisfy({ strings[$0.rawValue]?.isEmpty == false && localizer.text($0) != $0.rawValue }) else {
                    fputs("LaunchTablet localization resources are incomplete.\n", stderr)
                    exit(1)
                }
            }
            print("LaunchTablet: en and zh-Hans localization resources verified (\(TextKey.allCases.count) keys each).")
            return
        }
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--export-icon" {
            do { try LauncherIcon.export(to: URL(fileURLWithPath: CommandLine.arguments[2])) }
            catch { fputs("Icon generation failed: \(error)\n", stderr); exit(1) }
            return
        }
        let delegate = AppDelegate()
        application.delegate = delegate
        // 辅助应用不主动切换台前调度中的应用组；Dock 入口需要用户固定图标。
        application.setActivationPolicy(.accessory)
        // NSApplication 的 delegate 是弱引用，确保事件循环期间 delegate 不被 ARC（引用计数）回收。
        withExtendedLifetime(delegate) { application.run() }
    }
}

final class LauncherWindow: NSPanel {
    var escapePressed: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { escapePressed?() }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // 验收包单独保存布局，拖动和隐藏的测试不会改动日常使用的排列。
    private lazy var model = LauncherModel(repository: isolatedTestMode
        ? LayoutRepository(fileURL: Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("layout.json"))
        : .standard)
    private let shortcut = GlobalShortcut()
    private var window: LauncherWindow!
    private var eventMonitor: Any?
    private var directoryWatcher: ApplicationDirectoryWatcher?
    private var screenObserver: NSObjectProtocol?
    private var isHiding = false
    private var animationSequence = 0
    private var trackingMenu = false
    private let secondaryTestMode = Bundle.main.object(forInfoDictionaryKey: "LauncherTestOnSecondaryDisplay") as? Bool == true
    private let mainTestMode = Bundle.main.object(forInfoDictionaryKey: "LauncherTestOnMainDisplay") as? Bool == true
    private var isolatedTestMode: Bool { secondaryTestMode || mainTestMode }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.applicationIconImage = LauncherIcon.image(size: 512)
        configureMenu()
        configureWindow()
        NotificationCenter.default.addObserver(self, selector: #selector(launcherResignedKey), name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(menuTrackingBegan), name: NSMenu.didBeginTrackingNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(menuTrackingEnded), name: NSMenu.didEndTrackingNotification, object: nil)
        model.dismissRequested = { [weak self] in self?.hideLauncher() }
        model.languageChanged = { [weak self] in self?.configureMenu() }
        model.shortcutChanged = { [weak self] preset in self?.registerShortcut(preset) }
        shortcut.action = { [weak self] in self?.toggleLauncher() }
        registerShortcut(model.shortcut)
        directoryWatcher = ApplicationDirectoryWatcher { [weak self] in self?.model.scheduleRefresh() }
        screenObserver = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.window.isVisible else { return }
                if !self.positionWindow() { self.hideLauncher() }
            }
        }

        // 这是本进程的本地事件监视器，不是监听其他应用的全局键盘钩子。
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel]) { [weak self] event in
            // 本地监视器只收到本进程事件；后台窗口收到的定向滚轮/按键也应正常处理。
            guard let self, self.window.isVisible, !self.isHiding else { return event }
            // 拖拽期间由 AppKit 的原生循环处理 Esc，避免把取消拖拽误当作收起整个启动器。
            if self.model.draggedItemID != nil && event.type == .keyDown { return event }
            // 原生右键菜单打开时，把方向键和 Esc 留给菜单处理。
            if !self.trackingMenu, event.type == .keyDown, self.model.handleKey(event) { return nil }
            if !self.trackingMenu, event.type == .scrollWheel, self.model.handleScroll(event) { return nil }
            return event
        }
        // 冷启动只在后台准备列表；Dock 再次点击或快捷键才呼出窗口。
        model.refreshApplications()
    }

    private func configureWindow() {
        // 非激活面板可以接收键盘输入，同时不必把原应用从台前调度移走。
        window = LauncherWindow(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        window.title = AppIdentity.name
        window.identifier = NSUserInterfaceItemIdentifier("launcher")
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        // 覆盖当前桌面而不创建新的全屏 Space，也允许在其他应用的全屏 Space 中呼出。
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .canJoinAllApplications, .stationary, .ignoresCycle]
        window.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 1)
        window.escapePressed = { [weak self] in self?.model.handleEscape() }
        window.contentView = NSHostingView(rootView: LauncherView(model: model))
    }

    @discardableResult
    private func positionWindow() -> Bool {
        // NSEvent/NSScreen 使用逻辑点和左下角原点；Retina 上不需要手动乘像素比例。
        let mouse = NSEvent.mouseLocation
        let screens = NSScreen.screens
        let screen: NSScreen
        if secondaryTestMode {
            // 实机验收包固定到副屏；副屏断开时停止显示，不能退回主屏打扰用户。
            guard let secondary = screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value != CGMainDisplayID() }) else { return false }
            screen = secondary
        } else if mainTestMode {
            guard let primary = screens.first(where: { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == CGMainDisplayID() }) else { return false }
            screen = primary
        } else {
            guard let target = screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main ?? screens.first else { return false }
            screen = target
        }
        window.setFrame(screen.frame, display: true)
        model.updateWallpaper(for: screen)
        let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        Logger(subsystem: "com.local.launchtablet", category: "Window").debug("displayPrimary=\(displayID == CGMainDisplayID(), privacy: .public) size=\(screen.frame.width, privacy: .public)x\(screen.frame.height, privacy: .public)")
        return true
    }

    @objc private func toggleLauncher() {
        if window.isVisible && !isHiding { hideLauncher() }
        else { showLauncher() }
    }

    private func showLauncher() {
        animationSequence += 1
        isHiding = false
        guard positionWindow() else { return }
        model.prepareToShow()
        window.alphaValue = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 1 : 0
        window.makeKeyAndOrderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.12 : 0.34
            window.animator().alphaValue = 1
        }
    }

    private func hideLauncher() {
        guard window.isVisible, !isHiding else { return }
        isHiding = true
        animationSequence += 1
        let sequence = animationSequence
        model.prepareToHide()
        NSAnimationContext.runAnimationGroup({ context in
            // 比内容的 0.32 秒动画稍长，等缩放淡出结束后再移除窗口。
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.12 : 0.34
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor in
                guard let self, self.animationSequence == sequence else { return }
                self.window.orderOut(nil)
                self.isHiding = false
            }
        })
    }

    @objc private func launcherResignedKey(_ notification: Notification) {
        // 面板失焦可能是弹出菜单或设置窗口；等 AppKit 完成焦点切换后再判断。
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.secondaryTestMode, !self.trackingMenu,
                  self.window.isVisible, !self.window.isKeyWindow, NSApp.keyWindow == nil else { return }
            self.hideLauncher()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // 已经显示时只恢复焦点。再次激活 Dock 图标不能把正在输入的搜索词和页码清掉。
        if window.isVisible && !isHiding { window.makeKeyAndOrderFront(nil) }
        else { showLauncher() }
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func registerShortcut(_ preset: ShortcutPreset) {
        guard !isolatedTestMode else { return }
        if !shortcut.register(preset) {
            model.failure = .shortcutUnavailable(preset)
        }
    }

    @objc private func showSettings() {
        if !window.isVisible || isHiding { showLauncher() }
        model.isSettingsPresented = true
    }

    @objc private func showAbout() {
        // 关于面板是普通系统窗口，先收起高层级覆盖窗口，避免面板被挡在后面。
        animationSequence += 1
        isHiding = false
        model.prepareToHide()
        window.orderOut(nil)
        NSApp.orderFrontStandardAboutPanel(options: [.applicationName: AppIdentity.name])
    }
    @objc private func menuTrackingBegan() { trackingMenu = true }
    @objc private func menuTrackingEnded() { trackingMenu = false }

    private func configureMenu() {
        let menu = NSMenu()
        let applicationMenu = NSMenu()
        let item = NSMenuItem()
        item.submenu = applicationMenu
        menu.addItem(item)
        let about = applicationMenu.addItem(withTitle: model.text(.aboutApplication), action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        applicationMenu.addItem(.separator())
        let toggle = applicationMenu.addItem(withTitle: model.text(.toggleApplication), action: #selector(toggleLauncher), keyEquivalent: "")
        toggle.target = self
        let settings = applicationMenu.addItem(withTitle: model.text(.menuSettings), action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(withTitle: model.text(.quitApplication), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // 自己接管 AppKit main 后需要建立编辑菜单，才能让原生文本框响应 ⌘C/⌘V 等快捷键。
        let edit = NSMenu(title: model.text(.editMenu))
        for (title, action, key) in [(TextKey.undo, "undo:", "z"), (.cut, "cut:", "x"), (.copy, "copy:", "c"), (.paste, "paste:", "v"), (.selectAll, "selectAll:", "a")] {
            edit.addItem(withTitle: model.text(title), action: Selector(action), keyEquivalent: key)
        }
        let editItem = NSMenuItem(title: model.text(.editMenu), action: nil, keyEquivalent: "")
        editItem.submenu = edit
        menu.addItem(editItem)
        NSApp.mainMenu = menu
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }
}
