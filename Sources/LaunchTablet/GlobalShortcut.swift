import AppKit
import Carbon

enum ShortcutPreset: String, CaseIterable, Identifiable {
    case controlOptionSpace
    case commandShiftSpace
    case optionSpace
    case disabled

    var id: String { rawValue }
    func label(using localizer: Localizer) -> String {
        switch self {
        case .controlOptionSpace: return "⌃ ⌥ " + localizer.text(.spaceKey)
        case .commandShiftSpace: return "⇧ ⌘ " + localizer.text(.spaceKey)
        case .optionSpace: return "⌥ " + localizer.text(.spaceKey)
        case .disabled: return localizer.text(.shortcutDisabled)
        }
    }
    var modifiers: UInt32 {
        switch self {
        case .controlOptionSpace: return UInt32(controlKey | optionKey)
        case .commandShiftSpace: return UInt32(cmdKey | shiftKey)
        case .optionSpace: return UInt32(optionKey)
        case .disabled: return 0
        }
    }
}

/// Carbon 只用于注册系统快捷键，无需“辅助功能”或“输入监控”权限。
/// EventHotKeyRef 相当于系统返回的注册句柄，切换设置/销毁对象时必须注销。
final class GlobalShortcut {
    var action: (() -> Void)?
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    init() {
        var event = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let shortcut = Unmanaged<GlobalShortcut>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { shortcut.action?() }
            return noErr
        }, 1, &event, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    @discardableResult
    func register(_ preset: ShortcutPreset) -> Bool {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
        guard preset != .disabled else { return true }
        let identifier = EventHotKeyID(signature: OSType(0x4C504144), id: 1)
        return RegisterEventHotKey(UInt32(kVK_Space), preset.modifiers, identifier, GetApplicationEventTarget(), 0, &hotKey) == noErr
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
