import AppKit
import Foundation
import SwiftUI

/// 外观模式（FR-07）：跟随系统 / 白天 / 黑夜
enum ThemeMode: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "白天"
        case .dark: return "黑夜"
        }
    }

    var systemImage: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }

    /// 落到 AppKit 的外观。`nil` = 跟随系统。
    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light: return .aqua
        case .dark: return .darkAqua
        }
    }
}

/// 外观落地：把主题偏好写到 `NSApp.appearance`。
///
/// 为什么不用 SwiftUI 的 `.preferredColorScheme` 了事：它只影响 SwiftUI 自己画的子树，
/// 而编辑器（NSTextView / NSScrollView）、行号标尺、菜单、右键菜单、打开面板都是 AppKit 视图，
/// 只有改 `NSApp.appearance` 才能让深浅色真正覆盖整窗（含设置窗口）。
@MainActor
enum AppAppearance {
    static func apply(_ mode: ThemeMode) {
        let name = mode.appearanceName
        NSApp?.appearance = name.flatMap { NSAppearance(named: $0) }
    }
}

/// 编辑器字体族（FR-07：有限列表内选择）
/// 标签栏溢出策略（FR-05）：单行横向滚动 + 箭头 / 多行换行
enum TabBarStyle: String, CaseIterable, Identifiable {
    case scroll, wrap

    var id: String { rawValue }

    var label: String {
        switch self {
        case .scroll: return "单行"
        case .wrap: return "多行"
        }
    }

    var detail: String {
        switch self {
        case .scroll: return "始终一行；放不下时两侧出现滚动箭头，切换标签会自动滚到可见位置。"
        case .wrap: return "按窗口宽度自动换行，最多 3 行；超过 3 行时标签栏内部可上下滚动。"
        }
    }

    var systemImage: String {
        switch self {
        case .scroll: return "arrow.left.and.right"
        case .wrap: return "rectangle.grid.1x2"
        }
    }
}

enum EditorFontFamily: String, CaseIterable, Identifiable {
    case sfMono, menlo, systemMono, iAWriterMono

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sfMono: return "SF Mono"
        case .menlo: return "Menlo"
        case .systemMono: return "系统等宽"
        case .iAWriterMono: return "iA Writer Mono"
        }
    }

    var postScriptName: String {
        switch self {
        case .sfMono: return "SFMono-Regular"
        case .menlo: return "Menlo-Regular"
        case .systemMono: return "Menlo-Regular"
        case .iAWriterMono: return "iAWriterMonoS-Regular"
        }
    }
}

/// 应用设置：主题 / 字体 / 字号 / 行号 / 最近打开（FR-07、FR-08）
/// 全部持久化到 UserDefaults，结构变更向后兼容（缺键走默认值）。
@MainActor
final class AppSettings: ObservableObject {

    private enum Key {
        static let theme = "swiftdown.theme"
        static let fontFamily = "swiftdown.fontFamily"
        static let fontSize = "swiftdown.fontSize"
        static let showLineNumbers = "swiftdown.showLineNumbers"
        static let recent = "swiftdown.recentFiles"
        static let mode = "swiftdown.viewMode"
        static let shortcuts = "swiftdown.shortcuts"
        static let defaultViewMode = "swiftdown.defaultViewMode"
        static let restoreLastLayout = "swiftdown.restoreLastLayout"
        static let tabBarStyle = "swiftdown.tabBarStyle"
    }

    static let recentLimit = 20

    private let defaults: UserDefaults

    /// 暴露给同进程的其他组件（如 Workspace 读上次布局）。
    /// 自检时注入的是独立域，避免污染真实设置。
    var userDefaults: UserDefaults { defaults }

    @Published var themeMode: ThemeMode {
        didSet {
            defaults.set(themeMode.rawValue, forKey: Key.theme)
            // 设置里改、菜单里改、恢复默认，都从这一处落地到 AppKit 外观
            AppAppearance.apply(themeMode)
        }
    }

    @Published var fontFamily: EditorFontFamily {
        didSet { defaults.set(fontFamily.rawValue, forKey: Key.fontFamily) }
    }

    @Published var fontSize: Double {
        didSet { defaults.set(fontSize, forKey: Key.fontSize) }
    }

    @Published var showLineNumbers: Bool {
        didSet { defaults.set(showLineNumbers, forKey: Key.showLineNumbers) }
    }

    /// 启动时的默认布局（仅在「恢复上次布局」关闭，或没有上次记录时生效）
    @Published var defaultViewMode: ViewMode {
        didSet { defaults.set(defaultViewMode.rawValue, forKey: Key.defaultViewMode) }
    }

    /// 启动时是否沿用上一次会话的布局（默认开：多数人期望「上次什么样就什么样」）
    @Published var restoreLastLayout: Bool {
        didSet { defaults.set(restoreLastLayout, forKey: Key.restoreLastLayout) }
    }

    /// 标签栏溢出策略（FR-05）：默认单行滚动，标签多的人可切多行
    @Published var tabBarStyle: TabBarStyle {
        didSet { defaults.set(tabBarStyle.rawValue, forKey: Key.tabBarStyle) }
    }

    /// 快捷键覆写表（只存用户改过的，未设置的动作走 `defaultBinding`）。
    /// 存字典而不是全量列表：将来新增动作时老用户的设置不会因缺键而失效。
    @Published private(set) var shortcutOverrides: [String: ShortcutBinding] {
        didSet {
            guard let data = try? JSONEncoder().encode(shortcutOverrides) else { return }
            defaults.set(data, forKey: Key.shortcuts)
        }
    }

    /// 最近打开（去重、最新在前、上限 20，失效条目保留供置灰展示）
    @Published private(set) var recentPaths: [String] {
        didSet { defaults.set(recentPaths, forKey: Key.recent) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.themeMode = ThemeMode(rawValue: defaults.string(forKey: Key.theme) ?? "") ?? .system
        self.fontFamily = EditorFontFamily(rawValue: defaults.string(forKey: Key.fontFamily) ?? "") ?? .sfMono
        let storedSize = defaults.double(forKey: Key.fontSize)
        self.fontSize = storedSize > 0 ? storedSize : 13.5
        self.showLineNumbers = defaults.object(forKey: Key.showLineNumbers) as? Bool ?? true
        self.defaultViewMode = ViewMode(rawValue: defaults.string(forKey: Key.defaultViewMode) ?? "") ?? .split
        self.restoreLastLayout = defaults.object(forKey: Key.restoreLastLayout) as? Bool ?? true
        self.tabBarStyle = TabBarStyle(rawValue: defaults.string(forKey: Key.tabBarStyle) ?? "") ?? .scroll
        if let data = defaults.data(forKey: Key.shortcuts),
           let decoded = try? JSONDecoder().decode([String: ShortcutBinding].self, from: data) {
            self.shortcutOverrides = decoded
        } else {
            self.shortcutOverrides = [:]
        }
        self.recentPaths = defaults.stringArray(forKey: Key.recent) ?? []
    }

    // MARK: - 快捷键

    func binding(for action: ShortcutAction) -> ShortcutBinding {
        shortcutOverrides[action.rawValue] ?? action.defaultBinding
    }

    func isCustomized(_ action: ShortcutAction) -> Bool {
        shortcutOverrides[action.rawValue] != nil
    }

    func setBinding(_ binding: ShortcutBinding, for action: ShortcutAction) {
        var next = shortcutOverrides
        next[action.rawValue] = binding
        shortcutOverrides = next
    }

    func resetBinding(for action: ShortcutAction) {
        var next = shortcutOverrides
        next.removeValue(forKey: action.rawValue)
        shortcutOverrides = next
    }

    func resetAllShortcuts() {
        shortcutOverrides = [:]
    }

    /// 与其他动作的冲突检测（同键位 + 同修饰键）
    func conflict(for binding: ShortcutBinding, excluding action: ShortcutAction) -> ShortcutAction? {
        ShortcutAction.allCases.first {
            $0 != action && self.binding(for: $0).signature == binding.signature
        }
    }

    var hasCustomizedShortcuts: Bool { !shortcutOverrides.isEmpty }

    func noteOpened(_ url: URL) {
        // 临时文件不进「最近打开」：否则自检产物会出现在用户首页，点开就是冲突弹窗
        if !Workspace.isSelfTest, Workspace.isTemporaryPath(url.path) { return }
        var list = recentPaths.filter { $0 != url.path }
        list.insert(url.path, at: 0)
        if list.count > Self.recentLimit { list = Array(list.prefix(Self.recentLimit)) }
        recentPaths = list
    }

    func removeRecent(_ path: String) {
        recentPaths.removeAll { $0 == path }
    }

    func clearRecent() {
        recentPaths = []
    }

    static func exists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}
