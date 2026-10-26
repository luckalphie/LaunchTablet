import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// SwiftUI View 描述“当前状态下应该显示什么”，不是按执行顺序创建控件。
/// @ObservedObject 订阅 Model；@State 只保存悬停、焦点等局部 UI 状态，业务布局统一放在 Model。
struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    @FocusState private var searchFocused: Bool
    @State private var hasAppeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { screen in
            let metrics = GridMetrics(screenSize: screen.size)
            ZStack {
                desktopBackground(size: screen.size)
                    .onTapGesture { model.dismissRequested?() }
                VStack(spacing: 0) {
                    searchField
                        .frame(width: min(360, metrics.width * 0.65), height: 36)
                        .padding(.top, 20)
                        .padding(.bottom, 30)
                        .accessibilityHidden(model.openFolderID != nil)
                    if model.isLoading {
                        ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if model.rootItems.isEmpty {
                        ContentUnavailableView(model.query.isEmpty ? model.text(.noApplications) : model.text(.noResults), systemImage: model.query.isEmpty ? "square.grid.3x3" : "magnifyingglass", description: Text(model.query.isEmpty ? model.text(.restoreHiddenHint) : model.text(.searchHint)))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        PagedApplicationGrid(model: model, items: model.rootItems, columns: metrics.columns, rows: metrics.rows, page: model.page, iconSize: metrics.iconSize)
                            .padding(.horizontal, 14)
                    }
                    PageDots(localizer: model.localizer, count: model.rootPageCount, current: model.page, hidden: model.openFolderID != nil) { model.setPage($0) }
                        .padding(.top, 16)
                        .padding(.bottom, 18)
                }
                .scaleEffect(reduceMotion || model.openFolderID == nil ? 1 : 0.97)
                .blur(radius: reduceMotion || model.openFolderID == nil ? 0 : 3)
                .allowsHitTesting(model.openFolderID == nil)
                .frame(width: metrics.width, height: metrics.height)
                .position(x: screen.size.width / 2, y: screen.size.height / 2)

                if model.rootPageCount > 1 && model.openFolderID == nil {
                    HStack {
                        PageEdge(model: model, direction: -1, enabled: model.page > 0)
                        Spacer()
                        PageEdge(model: model, direction: 1, enabled: model.page < model.rootPageCount - 1)
                    }
                    .frame(width: min(screen.size.width - 12, metrics.width + 72))
                    .position(x: screen.size.width / 2, y: screen.size.height / 2)
                }

                footer.accessibilityHidden(model.openFolderID != nil)

                if let folder = model.openFolder {
                    Color.black.opacity(0.32)
                        .onTapGesture { model.closeFolder() }
                        .onDrop(of: [UTType.launcherItem], delegate: FolderExitDropDelegate(model: model))
                    FolderPanel(model: model, folder: folder, availableSize: screen.size)
                        .transition(reduceMotion ? .opacity : .scale(scale: 0.88).combined(with: .opacity))
                }
            }
            // 接近 iPad 主屏幕的落定感：从放大 12% 缩回原尺寸，收起时反向放大淡出。
            // scaleEffect 只改变绘制，不改变网格布局；“减少动态效果”下只保留淡入淡出。
            .scaleEffect(reduceMotion || (model.isPresented && hasAppeared) ? 1 : 1.12)
            .opacity(model.isPresented && hasAppeared ? 1 : 0)
            .animation(.easeOut(duration: reduceMotion ? 0.12 : 0.32), value: model.isPresented && hasAppeared)
            .allowsHitTesting(model.isPresented)
            .onAppear { hasAppeared = true; model.updateGrid(columns: metrics.columns, rows: metrics.rows); searchFocused = true }
            .onChange(of: metrics) { _, value in model.updateGrid(columns: value.columns, rows: value.rows) }
        }
        .environment(\.locale, model.localizer.locale)
        .preferredColorScheme(.dark)
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .spring(response: 0.3, dampingFraction: 0.87), value: model.openFolderID)
        .onChange(of: model.presentationID) { _, _ in searchFocused = true }
        .onChange(of: model.openFolderID) { _, value in searchFocused = value == nil }
        .alert(model.text(.operationFailed), isPresented: Binding(get: { model.errorText != nil }, set: { if !$0 { model.failure = nil } })) {
            Button(model.text(.okay), role: .cancel) { model.failure = nil }
        } message: { Text(model.errorText ?? "") }
    }

    private func desktopBackground(size: CGSize) -> some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.13, green: 0.19, blue: 0.29), Color(red: 0.12, green: 0.12, blue: 0.22), Color(red: 0.06, green: 0.09, blue: 0.15)], startPoint: .topLeading, endPoint: .bottomTrailing)
            if let wallpaper = model.wallpaper {
                Image(nsImage: wallpaper).resizable().scaledToFill()
                    .frame(width: size.width, height: size.height)
                    .blur(radius: 26, opaque: true)
                    .overlay(.black.opacity(0.38))
                    .clipped()
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
    }

    private var searchField: some View {
        HStack(spacing: 9) {
            Image(systemName: "magnifyingglass").font(.system(size: 14)).foregroundStyle(.white.opacity(0.65))
            TextField(model.text(.search), text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($searchFocused)
                .accessibilityIdentifier("application-search")
            if !model.query.isEmpty {
                Button {
                    model.query = ""
                    searchFocused = true
                } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.white.opacity(0.6)) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.text(.clearSearch))
            }
        }
        .padding(.horizontal, 13)
        .frame(maxHeight: .infinity)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.11), lineWidth: 1))
    }

    private var footer: some View {
        VStack {
            Spacer()
            HStack {
                Button { model.isHelpPresented.toggle() } label: {
                    Label(model.shortcut == .disabled ? model.text(.keyboardControls) : model.shortcutLabel, systemImage: "keyboard")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.48))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $model.isHelpPresented) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(model.text(.helpTitle)).font(.headline)
                        Text(model.text(.helpBody))
                            .font(.system(size: 13)).lineSpacing(6)
                    }.padding(22).frame(maxWidth: 480, alignment: .leading)
                }
                Spacer()
                Button { model.isSettingsPresented.toggle() } label: {
                    Image(systemName: "gearshape").font(.system(size: 17)).foregroundStyle(.white.opacity(0.55))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(model.text(.settings))
                .accessibilityIdentifier("launcher-settings")
                .popover(isPresented: $model.isSettingsPresented) { LauncherSettings(model: model) }
            }
        }
        .padding(24)
    }
}

private struct GridMetrics: Equatable {
    let width: CGFloat
    let height: CGFloat
    let columns: Int
    let rows: Int
    let iconSize: CGFloat

    init(screenSize: CGSize) {
        // 逻辑点上限对应之前确认的 14 寸体验，不按显示器物理英寸换算，也不随大屏无限拉开。
        width = min(1120, max(300, screenSize.width - 88))
        height = min(790, max(330, screenSize.height - 72))
        columns = width < 760 ? 5 : 7
        rows = height < 560 ? 4 : 5
        iconSize = min(78, max(42, min(width / CGFloat(columns) * 0.52, (height - 150) / CGFloat(rows) * 0.64)))
    }
}

private struct PagedApplicationGrid: View {
    @ObservedObject var model: LauncherModel
    let items: [LauncherItem]
    let columns: Int
    let rows: Int
    let page: Int
    let iconSize: CGFloat
    var isFolderGrid = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var capacity: Int { columns * rows }
    private var count: Int { LauncherModel.pageCount(itemCount: items.count, capacity: capacity) }

    var body: some View {
        GeometryReader { viewport in
            let spacing: CGFloat = 14
            let cellWidth = max(1, (viewport.size.width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
            let cellHeight = max(1, (viewport.size.height - CGFloat(rows - 1) * spacing) / CGFloat(rows))
            HStack(spacing: 0) {
                ForEach(0..<count, id: \.self) { pageIndex in
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(cellWidth), spacing: spacing), count: columns), spacing: spacing) {
                        let pageItems = Array(items.dropFirst(pageIndex * capacity).prefix(capacity))
                        // 业务 ID 保持 View 身份稳定，重排才有位移动画，隐藏才有离场动画。
                        ForEach(pageItems) { item in
                            ApplicationTile(model: model, item: item, iconSize: iconSize, width: cellWidth)
                                .frame(width: cellWidth, height: cellHeight)
                                .transition(reduceMotion ? .opacity : .scale(scale: 0.65).combined(with: .opacity))
                        }
                        ForEach(pageItems.count..<capacity, id: \.self) { _ in
                            Color.clear.frame(width: cellWidth, height: cellHeight).contentShape(Rectangle())
                                .onTapGesture { if !isFolderGrid { model.dismissRequested?() } }
                                .onDrop(of: [UTType.launcherItem], delegate: EmptySlotDropDelegate(model: model))
                        }
                    }
                    .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(response: 0.28, dampingFraction: 0.86), value: items)
                    .frame(width: viewport.size.width, height: viewport.size.height, alignment: .top)
                    .accessibilityHidden(pageIndex != page || (!isFolderGrid && model.openFolderID != nil))
                    .allowsHitTesting(pageIndex == page)
                    .accessibilityScrollAction { edge in
                        // Edge 表示内容移动方向；向前翻页时内容向 leading/top 移动。
                        switch edge {
                        case .leading, .top: model.turnPage(by: 1)
                        case .trailing, .bottom: model.turnPage(by: -1)
                        }
                    }
                }
            }
            .offset(x: -CGFloat(page) * viewport.size.width + (model.openFolderID == nil || isFolderGrid ? model.scrollOffset : 0))
            .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.88), value: page)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: model.isScrolling)
            .frame(width: viewport.size.width, height: viewport.size.height, alignment: .leading)
            // clipped 只裁剪绘制；同时限制命中区域，防止屏幕外的下一页图标响应背景点击。
            .contentShape(Rectangle())
            .clipped()
            .accessibilityElement(children: .contain)
            .accessibilityScrollAction { edge in
                switch edge {
                case .leading, .top: model.turnPage(by: 1)
                case .trailing, .bottom: model.turnPage(by: -1)
                }
            }
        }
    }
}

private struct ApplicationTile: View {
    @ObservedObject var model: LauncherModel
    let item: LauncherItem
    let iconSize: CGFloat
    let width: CGFloat
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if model.query.isEmpty {
                tile
                    .overlay { LauncherDragSource(model: model, item: item, iconSize: iconSize) }
            } else { tile }
        }
        .opacity(model.draggedItemID == item.id ? 0.32 : 1)
        .scaleEffect(model.draggedItemID == item.id && !reduceMotion ? 0.94 : 1)
        .overlay(alignment: model.dropAfter ? .trailing : .leading) {
            if model.dropTargetID == item.id && !model.isGroupingDrop {
                Capsule().fill(.white.opacity(0.9)).frame(width: 3).padding(.vertical, 12).allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if model.dropTargetID == item.id && model.isGroupingDrop {
                Image(systemName: "plus.circle.fill").font(.system(size: 22)).symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .blue).padding(4).allowsHitTesting(false)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: model.isGroupingDrop)
        .contextMenu { contextMenu }
    }

    private var tile: some View {
        Button { model.activate(item) } label: {
            VStack(spacing: 9) {
                Group {
                    if item.isFolder { FolderIcon(model: model, item: item, size: iconSize) }
                    else if let application = model.application(for: item) {
                        Image(nsImage: model.icons.image(for: application))
                            .resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                    }
                }
                .frame(width: iconSize, height: iconSize)
                .shadow(color: .black.opacity(0.2), radius: 5, y: 3)
                .scaleEffect(!reduceMotion && (hovering || (model.dropTargetID == item.id && model.isGroupingDrop)) ? 1.055 : 1)
                Text(model.title(for: item))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(1).truncationMode(.tail)
                    .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(RoundedRectangle(cornerRadius: 15))
            .background(tileHighlight, in: RoundedRectangle(cornerRadius: 15))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(model.selectedItemID == item.id ? .white.opacity(0.5) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovering)
        .help(model.title(for: item))
        .accessibilityLabel(model.title(for: item))
        .accessibilityIdentifier(item.id)
    }

    private var tileHighlight: Color {
        if model.dropTargetID == item.id { return .white.opacity(model.isGroupingDrop ? 0.25 : 0.12) }
        if model.selectedItemID == item.id { return .white.opacity(0.11) }
        return .clear
    }

    @ViewBuilder private var contextMenu: some View {
        if item.isFolder {
            Button(model.text(.openFolder)) { model.activate(item) }
            Button(model.text(.renameFolder)) { model.activate(item); model.isRenamingFolder = true }
            Divider()
            Button(model.text(.dissolveFolder)) { model.dissolveFolder(item) }
        } else {
            Button(model.text(.openApplication)) { model.activate(item) }
            Button(model.text(.revealInFinder)) { model.reveal(item) }
            Divider()
            if model.openFolderID != nil { Button(model.text(.moveOutOfFolder)) { model.removeFromFolder(item) } }
            else if model.query.isEmpty { Button(model.text(.newFolder)) { model.createFolder(for: item) } }
            Button(model.text(.hideApplication)) { model.hideApplication(item) }
        }
    }
}

private struct FolderIcon: View {
    @ObservedObject var model: LauncherModel
    let item: LauncherItem
    let size: CGFloat

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 3), count: 3), spacing: 3) {
            ForEach(0..<9, id: \.self) { index in
                if index < item.applicationIDs.count, let app = model.application(id: item.applicationIDs[index]) {
                    Image(nsImage: model.icons.image(for: app)).resizable().aspectRatio(contentMode: .fit)
                        .frame(width: size * 0.22, height: size * 0.22)
                } else { Color.clear.frame(width: size * 0.22, height: size * 0.22) }
            }
        }
        .padding(size * 0.1)
        .frame(width: size, height: size)
        .background(.white.opacity(0.2), in: RoundedRectangle(cornerRadius: size * 0.23))
        .overlay(RoundedRectangle(cornerRadius: size * 0.23).stroke(.white.opacity(0.16), lineWidth: 1))
    }
}

private struct PageDots: View {
    let localizer: Localizer
    let count: Int
    let current: Int
    var hidden = false
    let select: (Int) -> Void

    var body: some View {
        HStack(spacing: 0) {
            ForEach(0..<count, id: \.self) { index in
                Button { select(index) } label: {
                    Circle().fill(.white.opacity(index == current ? 0.95 : 0.27)).frame(width: 7, height: 7).padding(7)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(localizer.text(.pageDescription, arguments: [index + 1, count]))
                .accessibilityValue(index == current ? localizer.text(.currentPage) : "")
                .accessibilityIdentifier("page-\(index + 1)")
            }
        }
        .frame(height: 22)
        .opacity(count > 1 ? 1 : 0)
        .accessibilityHidden(hidden || count <= 1)
        .allowsHitTesting(!hidden && count > 1)
    }
}

private struct PageEdge: View {
    @ObservedObject var model: LauncherModel
    let direction: Int
    let enabled: Bool
    @State private var hovering = false

    var body: some View {
        Button { model.turnPage(by: direction) } label: {
            Image(systemName: direction < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 21, weight: .light))
                .frame(width: 32, height: 180)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? (hovering ? 0.8 : 0.17) : 0)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .onDrop(of: [UTType.launcherItem], delegate: PageEdgeDropDelegate(model: model, direction: direction))
        .accessibilityLabel(direction < 0 ? model.text(.previousPage) : model.text(.nextPage))
    }
}

private struct FolderPanel: View {
    @ObservedObject var model: LauncherModel
    let folder: LauncherItem
    let availableSize: CGSize
    @State private var name = ""
    @State private var originalName = ""
    @FocusState private var editingName: Bool

    var body: some View {
        VStack(spacing: 18) {
            HStack {
                TextField(model.text(.folderName), text: $name)
                    .textFieldStyle(.plain).font(.system(size: 24, weight: .medium))
                    .focused($editingName)
                    .onSubmit { commitName(); editingName = false }
                    .accessibilityIdentifier("folder-name")
                Button { model.closeFolder() } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 21)).foregroundStyle(.secondary)
                }.buttonStyle(.plain).accessibilityLabel(model.text(.closeFolder))
            }
            .padding(.horizontal, 12).padding(.top, 5)

            PagedApplicationGrid(model: model, items: model.folderItems, columns: 4, rows: 3, page: model.folderPage, iconSize: min(78, max(42, (availableSize.height - 260) / 6)), isFolderGrid: true)
                .overlay {
                    if model.folderPageCount > 1 {
                        HStack {
                            PageEdge(model: model, direction: -1, enabled: model.folderPage > 0)
                            Spacer()
                            PageEdge(model: model, direction: 1, enabled: model.folderPage < model.folderPageCount - 1)
                        }.padding(.horizontal, -28)
                    }
                }
            PageDots(localizer: model.localizer, count: model.folderPageCount, current: model.folderPage) { model.setPage($0) }
        }
        .padding(28)
        .frame(width: min(680, availableSize.width - 100), height: min(570, availableSize.height - 120))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 28))
        .overlay(RoundedRectangle(cornerRadius: 28).stroke(.white.opacity(0.14), lineWidth: 1))
        .shadow(color: .black.opacity(0.22), radius: 30, y: 12)
        .onAppear { name = model.title(for: folder); originalName = name; editingName = model.isRenamingFolder }
        .onChange(of: editingName) { _, editing in
            model.isRenamingFolder = editing
            if !editing { commitName() }
        }
        .onDisappear { commitName(); model.isRenamingFolder = false }
    }

    private func commitName() {
        // 展示层翻译不是用户重命名：仅编辑过的草稿才写回，避免打开英文分类后污染旧布局。
        guard name != originalName else { return }
        model.renameFolder(name, id: folder.id)
        originalName = name
    }
}

struct LauncherSettings: View {
    @ObservedObject var model: LauncherModel
    @State private var confirmsDefaultOrganization = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.text(.settingsTitle)).font(.headline)
            Text(model.text(.displayDescription, model.currentDisplayName)).font(.system(size: 12)).foregroundStyle(.secondary)
            Picker(model.text(.shortcutTitle), selection: $model.shortcut) {
                ForEach(ShortcutPreset.allCases) { preset in Text(preset.label(using: model.localizer)).tag(preset) }
            }
            Picker(model.text(.languageTitle), selection: $model.language) {
                Text(model.text(.systemLanguage)).tag(InterfaceLanguage.system)
                Text("简体中文").tag(InterfaceLanguage.simplifiedChinese)
                Text("English").tag(InterfaceLanguage.english)
            }
            .accessibilityIdentifier("interface-language")
            Divider()
            Button(model.text(.refreshApplications), systemImage: "arrow.clockwise") { model.refreshApplications() }
            Text(model.layout.isManuallyArranged ? model.text(.manualArrangement) : model.text(.defaultArrangement))
                .font(.system(size: 12)).foregroundStyle(.secondary)
            Button(model.text(.resetArrangement)) { confirmsDefaultOrganization = true }
                .disabled(model.isLoading || model.catalogWarning != nil)
                .confirmationDialog(model.text(.resetConfirmation), isPresented: $confirmsDefaultOrganization, titleVisibility: .visible) {
                    Button(model.text(.resetButton), role: .destructive) { model.restoreDefaultOrganization() }
                    Button(model.text(.cancel), role: .cancel) { }
                } message: {
                    Text(model.text(.resetExplanation))
                }
            if let warning = model.catalogWarning { Text(warning).font(.system(size: 12)).foregroundStyle(.orange) }
            Menu(model.text(.hiddenApplications, model.hiddenApplications.count)) {
                if model.hiddenApplications.isEmpty { Text(model.text(.noHiddenApplications)) }
                ForEach(model.hiddenApplications) { application in
                    Button(model.text(.restoreApplication, application.name)) { model.restoreApplication(id: application.id) }
                }
            }
            Text(model.text(.organizationHelp))
                .font(.system(size: 12)).foregroundStyle(.secondary).lineSpacing(4)
            Divider()
            Button(model.text(.quitApplication)) { NSApp.terminate(nil) }
        }
        .padding(22).frame(width: 370)
    }
}

@MainActor
private struct PageEdgeDropDelegate: DropDelegate {
    let model: LauncherModel
    let direction: Int
    func validateDrop(info: DropInfo) -> Bool { model.draggedItemID != nil }
    func dropEntered(info: DropInfo) { model.beginPageHover(direction: direction) }
    func dropExited(info: DropInfo) { model.endPageHover() }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { model.endDragging(); return false }
}

@MainActor
private struct EmptySlotDropDelegate: DropDelegate {
    let model: LauncherModel
    func validateDrop(info: DropInfo) -> Bool { model.draggedItemID != nil }
    func dropEntered(info: DropInfo) { model.endPageHover(); model.updateDropTarget(nil, grouping: false) }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { model.dropIntoEmptySlot() }
}

/// 面板外区域仅负责“返回主网格”，不立即修改布局；Esc 或投放失败仍可完整撤销本次拖动。
@MainActor
private struct FolderExitDropDelegate: DropDelegate {
    let model: LauncherModel
    func validateDrop(info: DropInfo) -> Bool { model.draggedItemID != nil }
    func dropEntered(info: DropInfo) { model.beginFolderExitHover() }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func dropExited(info: DropInfo) { model.endFolderExitHover() }
    func performDrop(info: DropInfo) -> Bool {
        model.closeFolder()
        return model.dropIntoEmptySlot()
    }
}
