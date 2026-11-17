import AppKit
import SwiftUI

/// 快捷键修饰键。用数组而非 OptionSet 存储，保证 Codable 与显示顺序稳定。
enum ShortcutModifier: String, Codable, CaseIterable, Sendable {
    case control, option, shift, command

    /// 显示顺序固定为 ⌃⌥⇧⌘（与 macOS 菜单习惯一致）
    static let displayOrder: [ShortcutModifier] = [.control, .option, .shift, .command]

    var symbol: String {
        switch self {
        case .control: return "⌃"
        case .option: return "⌥"
        case .shift: return "⇧"
        case .command: return "⌘"
        }
    }

    var eventFlag: EventModifiers {
        switch self {
        case .control: return .control
        case .option: return .option
        case .shift: return .shift
        case .command: return .command
        }
    }
}

/// 一条快捷键绑定：单字符键位 + 修饰键组合。
/// 只支持「修饰键 + 单字符」，不做功能键（F1–F12）——那需要虚拟键码，
/// 且用户实际想改的几乎都是字母/数字/符号组合。
struct ShortcutBinding: Codable, Equatable, Sendable {

    /// 小写单字符（字母统一小写；符号原样保留，如 "]"、"+"、"1"）
    var key: String
    /// 已按显示顺序规范化
    var modifiers: [ShortcutModifier]

    init(key: String, modifiers: [ShortcutModifier]) {
        self.key = key.lowercased()
        self.modifiers = ShortcutModifier.displayOrder.filter { modifiers.contains($0) }
    }

    var isEmpty: Bool { key.isEmpty }

    /// 用于 SwiftUI `.keyboardShortcut`
    var keyEquivalent: KeyEquivalent {
        KeyEquivalent(Character(key.isEmpty ? " " : key))
    }

    var eventModifiers: EventModifiers {
        modifiers.reduce(into: EventModifiers()) { result, modifier in
            result.insert(modifier.eventFlag)
        }
    }

    /// 菜单/设置里显示的样子，如 ⌘⇧1
    var displayString: String {
        modifiers.map(\.symbol).joined() + key.uppercased()
    }

    /// 冲突判定用：等价即冲突
    var signature: String {
        modifiers.map(\.rawValue).joined(separator: "+") + ":" + key
    }

    static func from(event: NSEvent) -> ShortcutBinding? {
        guard let characters = event.charactersIgnoringModifiers?.lowercased(),
              characters.count == 1,
              let scalar = characters.unicodeScalars.first,
              !CharacterSet.controlCharacters.contains(scalar) else { return nil }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: [ShortcutModifier] = []
        if flags.contains(.command) { modifiers.append(.command) }
        if flags.contains(.shift) { modifiers.append(.shift) }
        if flags.contains(.option) { modifiers.append(.option) }
        if flags.contains(.control) { modifiers.append(.control) }
        return ShortcutBinding(key: characters, modifiers: modifiers)
    }
}

/// 可配置的菜单命令。rawValue 用作持久化键，改名会丢失用户设置，故固定。
enum ShortcutAction: String, CaseIterable, Identifiable, Sendable {

    // 文件
    case openFile
    case saveFile
    case saveAllFiles
    // 标签
    case closeTab
    case closeAllTabs
    case nextTab
    case previousTab
    // 视图
    case viewEditor
    case viewSplit
    case viewPreview
    case toggleOutline
    case toggleLineNumbers
    // 字号
    case increaseFont
    case decreaseFont

    var id: String { rawValue }

    var title: String {
        switch self {
        case .openFile: return "打开文件"
        case .saveFile: return "保存"
        case .saveAllFiles: return "全部保存"
        case .closeTab: return "关闭标签"
        case .closeAllTabs: return "关闭全部标签"
        case .nextTab: return "下一个标签"
        case .previousTab: return "上一个标签"
        case .viewEditor: return "仅源码"
        case .viewSplit: return "分屏"
        case .viewPreview: return "仅预览"
        case .toggleOutline: return "显示/隐藏大纲"
        case .toggleLineNumbers: return "显示/隐藏行号"
        case .increaseFont: return "增大字号"
        case .decreaseFont: return "减小字号"
        }
    }

    var group: String {
        switch self {
        case .openFile, .saveFile, .saveAllFiles: return "文件"
        case .closeTab, .closeAllTabs, .nextTab, .previousTab: return "标签"
        case .viewEditor, .viewSplit, .viewPreview, .toggleOutline,
             .toggleLineNumbers, .increaseFont, .decreaseFont: return "视图"
        }
    }

    var defaultBinding: ShortcutBinding {
        switch self {
        case .openFile: return ShortcutBinding(key: "o", modifiers: [.command])
        case .saveFile: return ShortcutBinding(key: "s", modifiers: [.command])
        case .saveAllFiles: return ShortcutBinding(key: "s", modifiers: [.command, .option])
        case .closeTab: return ShortcutBinding(key: "w", modifiers: [.command])
        case .closeAllTabs: return ShortcutBinding(key: "w", modifiers: [.command, .shift])
        case .nextTab: return ShortcutBinding(key: "]", modifiers: [.command, .shift])
        case .previousTab: return ShortcutBinding(key: "[", modifiers: [.command, .shift])
        case .viewEditor: return ShortcutBinding(key: "1", modifiers: [.command])
        case .viewSplit: return ShortcutBinding(key: "1", modifiers: [.command, .shift])
        case .viewPreview: return ShortcutBinding(key: "2", modifiers: [.command])
        case .toggleOutline: return ShortcutBinding(key: "0", modifiers: [.command, .option])
        case .toggleLineNumbers: return ShortcutBinding(key: "l", modifiers: [.command, .shift])
        case .increaseFont: return ShortcutBinding(key: "+", modifiers: [.command])
        case .decreaseFont: return ShortcutBinding(key: "-", modifiers: [.command])
        }
    }

    /// 分组顺序（设置页按此渲染）
    static let groupOrder = ["文件", "标签", "视图"]
}
