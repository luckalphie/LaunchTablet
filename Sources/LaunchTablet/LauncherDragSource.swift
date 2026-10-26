import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// 私有拖拽类型，避免把 Finder 文件或外部文本误当作启动器中的应用。
    static let launcherItem = UTType(exportedAs: "com.local.launchtablet.item", conformingTo: .data)
}

/// NSViewRepresentable 是 SwiftUI 与 AppKit 的桥接层；原生拖拽源能收到完成/取消回调。
/// 不依赖 mouseUp 清理，因为系统进入拖拽循环后可能不会再向原窗口发送该事件。
struct LauncherDragSource: NSViewRepresentable {
    let model: LauncherModel
    let item: LauncherItem
    let iconSize: CGFloat

    func makeNSView(context: Context) -> TileDragView { TileDragView() }

    func updateNSView(_ view: TileDragView, context: Context) {
        view.model = model
        view.item = item
        view.iconSize = iconSize
        view.setAccessibilityElement(false)
    }
}

@MainActor
final class TileDragView: NSView, NSDraggingSource {
    weak var model: LauncherModel?
    var item: LauncherItem?
    var iconSize: CGFloat = 78
    private var pressLocation: NSPoint?
    private var isDragging = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([NSPasteboard.PasteboardType(UTType.launcherItem.identifier)])
    }

    required init?(coder: NSCoder) { fatalError("TileDragView is created programmatically") }

    private func accepts(_ sender: NSDraggingInfo) -> Bool {
        guard let model, let item, model.activeItems.contains(where: { $0.id == item.id }),
              let sourceID = model.draggedItemID, sourceID != item.id else { return false }
        return sender.draggingPasteboard.string(forType: NSPasteboard.PasteboardType(UTType.launcherItem.identifier)) == sourceID
    }

    private func updateTarget(_ sender: NSDraggingInfo) {
        guard let model, let item else { return }
        let point = convert(sender.draggingLocation, from: nil)
        let grouping = model.canGroup(onto: item) && point.x > bounds.width * 0.23 && point.x < bounds.width * 0.77
            && bounds.height - point.y < iconSize + 20
        model.endPageHover()
        model.updateDropTarget(item.id, grouping: grouping, after: point.x > bounds.width / 2)
    }

    // 与拖拽源同用 AppKit，避免透明 NSView 遮住 SwiftUI 的图标投放命中区域。
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender) else { return [] }
        updateTarget(sender)
        return .move
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard accepts(sender) else { return [] }
        updateTarget(sender)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        if model?.dropTargetID == item?.id { model?.updateDropTarget(nil, grouping: false) }
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { accepts(sender) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard accepts(sender), let model, let item else { return false }
        updateTarget(sender)
        return model.performDrop(onto: item, grouping: model.dropTargetID == item.id && model.isGroupingDrop, after: model.dropAfter)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // 右键交还下层 SwiftUI，让原有 contextMenu 和辅助功能 Button 继续负责各自交互。
        if let event = NSApp.currentEvent,
           event.type == .rightMouseDown || event.type == .rightMouseUp || event.modifierFlags.contains(.control) { return nil }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        pressLocation = convert(event.locationInWindow, from: nil)
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !isDragging, let start = pressLocation, let model, let item else { return }
        let location = convert(event.locationInWindow, from: nil)
        guard hypot(location.x - start.x, location.y - start.y) >= 6 else { return }
        model.beginDragging(item)
        guard model.draggedItemID == item.id else { return }
        isDragging = true
        let pasteboard = NSPasteboardItem()
        pasteboard.setString(item.id, forType: NSPasteboard.PasteboardType(UTType.launcherItem.identifier))
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboard)
        // 普通应用使用高分辨率缓存图标；文件夹用系统符号生成轻量拖拽预览。
        let image: NSImage
        if let application = model.application(for: item), !item.isFolder {
            image = model.icons.image(for: application)
        } else {
            image = NSImage(systemSymbolName: "folder.fill", accessibilityDescription: nil) ?? NSImage(size: NSSize(width: iconSize, height: iconSize))
        }
        let frame = NSRect(x: location.x - iconSize / 2, y: location.y - iconSize / 2, width: iconSize, height: iconSize)
        draggingItem.setDraggingFrame(frame, contents: image)
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressLocation = nil }
        guard !isDragging, pressLocation != nil, bounds.contains(convert(event.locationInWindow, from: nil)), let item else { return }
        model?.activate(item)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        isDragging = false
        pressLocation = nil
        model?.endDragging()
    }
}
