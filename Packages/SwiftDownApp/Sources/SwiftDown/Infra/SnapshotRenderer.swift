import AppKit
import SwiftUI

/// 离屏渲染：把 SwiftUI 视图树渲成 PNG。
///
/// 为什么要塞进一个不显示的 `NSWindow`：SwiftUI 只有在窗口里才会走完整布局；
/// 直接 `layoutSubtreeIfNeeded()` 到一个游离的 NSHostingView 上常常拿到空白图。
@MainActor
enum SnapshotRenderer {

    @discardableResult
    static func render(_ view: NSView, to path: String, size: NSSize) -> NSSize? {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()

        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return nil }
        try? data.write(to: URL(fileURLWithPath: path))
        window.contentView = nil
        return NSSize(width: rep.pixelsWide, height: rep.pixelsHigh)
    }
}

/// `--render` 的出图作业：给文档截图用，非交互、不碰用户设置与真实会话。
///
/// 用独立 `UserDefaults` suite，保证每次出图都是「默认设置 + 指定参数」，
/// 不受用户当前主题/字体/布局影响；也不会把临时文档写进「最近打开」。
@MainActor
enum RenderJob {

    struct Options {
        var file: URL
        var out: String
        var size = NSSize(width: 1320, height: 860)
        var mode: ViewMode = .split
        var theme: ThemeMode?
        var outline = true
        var settingsPage: String?   // general / shortcuts
    }

    static let suiteName = "swiftdown.render"

    static func parse(_ arguments: [String]) -> Options? {
        guard let fileIndex = arguments.firstIndex(of: "--render"),
              arguments.count > fileIndex + 1 else { return nil }
        let file = URL(fileURLWithPath: arguments[fileIndex + 1])

        func value(for flag: String) -> String? {
            guard let index = arguments.firstIndex(of: flag), arguments.count > index + 1 else { return nil }
            return arguments[index + 1]
        }

        var options = Options(file: file, out: "/tmp/swiftdown-render.png")
        if let out = value(for: "--out") { options.out = out }
        if let raw = value(for: "--size") {
            let parts = raw.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 { options.size = NSSize(width: parts[0], height: parts[1]) }
        }
        if let raw = value(for: "--mode"), let mode = ViewMode(rawValue: raw) { options.mode = mode }
        if let raw = value(for: "--theme") { options.theme = ThemeMode(rawValue: raw) }
        if let raw = value(for: "--outline") { options.outline = (raw != "0" && raw != "false") }
        options.settingsPage = value(for: "--settings")
        return options
    }

    static func run(_ options: Options) async {
        // 独立设置域：出图结果只由参数决定
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let settings = AppSettings(defaults: defaults)
        if let theme = options.theme { settings.themeMode = theme }
        settings.showLineNumbers = true

        let workspace = Workspace(settings: settings,
                                  restoreSessionOnInit: false,
                                  sessionStore: SessionStore(directory: FileManager.default.temporaryDirectory
                                                                .appendingPathComponent("swiftdown-render-session")))
        workspace.showOutline = options.outline
        workspace.setViewMode(options.mode)
        workspace.open(url: options.file)

        // 等解析/排版完成（大纲与预览都依赖 AST）
        for _ in 0..<40 {
            if workspace.activeTab?.ast.blocks.isEmpty == false { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        try? await Task.sleep(nanoseconds: 700_000_000)

        let view: AnyView
        if let page = options.settingsPage {
            // 只渲内容页：TabView 的分页条在离屏窗口里会渲成空白（真机正常）
            view = AnyView((page == "shortcuts"
                            ? AnyView(ShortcutSettingsView())
                            : AnyView(GeneralSettingsView()))
                .environmentObject(settings))
        } else {
            view = AnyView(RootView()
                .environmentObject(settings)
                .environmentObject(workspace)
                .preferredColorScheme(settings.themeMode.colorScheme))
        }

        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: options.size)
        host.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 400_000_000)

        let pixels = SnapshotRenderer.render(host, to: options.out, size: options.size)
        print("[render] \(options.out) \(Int(pixels?.width ?? 0))x\(Int(pixels?.height ?? 0)) "
              + "mode=\(options.mode.rawValue) theme=\(settings.themeMode.rawValue)")

        try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftdown-render-session"))
        defaults.removePersistentDomain(forName: suiteName)
        NSApp.terminate(nil)
    }
}
