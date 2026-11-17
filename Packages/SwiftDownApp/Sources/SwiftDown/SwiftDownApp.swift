import AppKit
import SwiftUI

/// 应用级依赖容器：settings 与 workspace 的生命周期由它统一持有
@MainActor
final class AppEnvironment: ObservableObject {
    let settings: AppSettings
    let workspace: Workspace

    init() {
        // 自检跑在独立 UserDefaults 域里：真实用户的最近打开/快捷键/布局不能被测试污染
        let defaults: UserDefaults
        if CommandLine.arguments.contains("--selftest"),
           let suite = UserDefaults(suiteName: SelfTest.settingsSuiteName) {
            suite.removePersistentDomain(forName: SelfTest.settingsSuiteName)
            defaults = suite
        } else if CommandLine.arguments.contains("--render"),
                  let suite = UserDefaults(suiteName: RenderJob.suiteName) {
            defaults = suite
        } else {
            defaults = .standard
        }
        let settings = AppSettings(defaults: defaults)
        // 启动即落地外观（属性观察器在 init 里不会触发，必须显式应用一次）
        AppAppearance.apply(settings.themeMode)
        self.settings = settings
        self.workspace = Workspace(settings: settings)
    }
}

@main
struct SwiftDownApp: App {
    @StateObject private var env = AppEnvironment()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        // 单窗口场景：多文件靠窗口内标签管理（PRD FR-05），
        // 用 WindowGroup 会让「再次 open 同一 app」产生第二个窗口。
        Window("SwiftDown", id: "main") {
            RootView()
                .environmentObject(env.settings)
                .environmentObject(env.workspace)
                .preferredColorScheme(env.settings.themeMode.colorScheme)
                .frame(minWidth: 760, minHeight: 480)
                .onAppear {
                    delegate.attach(env)
                }
        }
        .defaultSize(width: 1180, height: 760)
        .commands {
            AppCommands(settings: env.settings, workspace: env.workspace)
        }

        // 设置窗口（⌘,）：默认布局、外观、编辑器、快捷键
        Settings {
            SettingsView()
                .environmentObject(env.settings)
        }
    }
}

// MARK: - 菜单命令

struct AppCommands: Commands {
    @ObservedObject var settings: AppSettings
    @ObservedObject var workspace: Workspace

    /// 从设置读取快捷键（用户可在设置里改）。
    /// 用 `Commands` + `@ObservedObject` 让菜单在设置变更后重建。
    private func shortcut(_ action: ShortcutAction) -> KeyboardShortcut {
        let binding = settings.binding(for: action)
        return KeyboardShortcut(binding.keyEquivalent, modifiers: binding.eventModifiers)
    }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("打开…") { workspace.presentOpenPanel() }
                .keyboardShortcut(shortcut(.openFile))

            Menu("最近打开") {
                if settings.recentPaths.isEmpty {
                    Text("暂无记录")
                } else {
                    ForEach(settings.recentPaths, id: \.self) { path in
                        Button {
                            workspace.open(url: URL(fileURLWithPath: path))
                        } label: {
                            Text(URL(fileURLWithPath: path).lastPathComponent
                                 + "  —  " + URL(fileURLWithPath: path).deletingLastPathComponent().path)
                        }
                        .disabled(!AppSettings.exists(path))
                    }
                    Divider()
                    Button("清除菜单") { settings.clearRecent() }
                }
            }

            Divider()
            Button("关闭标签") {
                if let tab = workspace.activeTab { workspace.requestClose(tab) }
            }
            .keyboardShortcut(shortcut(.closeTab))

            Button("关闭全部标签") { workspace.closeAll() }
                .keyboardShortcut(shortcut(.closeAllTabs))
        }

        CommandGroup(replacing: .saveItem) {
            Button("保存") { workspace.saveActive() }
                .keyboardShortcut(shortcut(.saveFile))
            Button("全部保存") { workspace.saveAll() }
                .keyboardShortcut(shortcut(.saveAllFiles))
        }

        CommandMenu("标签") {
            Button("下一个标签") { workspace.activateNext() }
                .keyboardShortcut(shortcut(.nextTab))
            Button("上一个标签") { workspace.activatePrevious() }
                .keyboardShortcut(shortcut(.previousTab))
            Divider()
            Button("关闭其他标签") {
                if let tab = workspace.activeTab { workspace.closeOthers(than: tab) }
            }
        }

        CommandMenu("视图") {
            Button("仅源码") { workspace.setViewMode(.editor) }
                .keyboardShortcut(shortcut(.viewEditor))
            Button("分屏") { workspace.setViewMode(.split) }
                .keyboardShortcut(shortcut(.viewSplit))
            Button("仅预览") { workspace.setViewMode(.preview) }
                .keyboardShortcut(shortcut(.viewPreview))

            Divider()

            Button(workspace.showOutline ? "隐藏大纲" : "显示大纲") {
                workspace.showOutline.toggle()
            }
            .keyboardShortcut(shortcut(.toggleOutline))

            Button(settings.showLineNumbers ? "隐藏行号" : "显示行号") {
                settings.showLineNumbers.toggle()
            }
            .keyboardShortcut(shortcut(.toggleLineNumbers))

            Divider()

            Button("增大字号") { settings.fontSize = min(28, settings.fontSize + 1) }
                .keyboardShortcut(shortcut(.increaseFont))
            Button("减小字号") { settings.fontSize = max(10, settings.fontSize - 1) }
                .keyboardShortcut(shortcut(.decreaseFont))

            Menu("字体") {
                ForEach(EditorFontFamily.allCases) { family in
                    Button {
                        settings.fontFamily = family
                    } label: {
                        if settings.fontFamily == family {
                            Label(family.label, systemImage: "checkmark")
                        } else {
                            Text(family.label)
                        }
                    }
                }
            }

            Menu("主题") {
                ForEach(ThemeMode.allCases) { mode in
                    Button {
                        settings.themeMode = mode
                    } label: {
                        if settings.themeMode == mode {
                            Label(mode.label, systemImage: "checkmark")
                        } else {
                            Text(mode.label)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {

    private weak var env: AppEnvironment?
    private var pendingURLs: [URL] = []
    private var didRunSelfTest = false

    @MainActor
    func attach(_ env: AppEnvironment) {
        guard self.env == nil else { return }
        self.env = env
        if !pendingURLs.isEmpty {
            env.workspace.open(urls: pendingURLs)
            pendingURLs.removeAll()
        }
        // 文档出图（非交互）：--render <md> --out <png> [--size WxH] [--mode editor|split|preview]
        //                              [--theme light|dark] [--outline 0|1] [--settings general|shortcuts]
        if let options = RenderJob.parse(CommandLine.arguments) {
            Task { @MainActor in await RenderJob.run(options) }
            return
        }

        if let index = CommandLine.arguments.firstIndex(of: "--selftest"), !didRunSelfTest {
            didRunSelfTest = true
            let target = CommandLine.arguments.count > index + 1
                ? CommandLine.arguments[index + 1]
                : nil
            Task { @MainActor in
                await SelfTest.run(workspace: env.workspace,
                                   settings: env.settings,
                                   sourcePath: target)
                NSApp.terminate(nil)
            }
        }

        // 帧级探针（仅排查用）：--start A.md --trace-open B.md
        // 等价于「先打开 A，再在运行中打开 B」，用于定位「闪一下」发生在哪一层。
        if let start = value(after: "--start"), let target = value(after: "--trace-open") {
            env.workspace.open(url: URL(fileURLWithPath: start))
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                env.workspace.open(url: URL(fileURLWithPath: target))
            }
        }
    }

    private func value(after flag: String) -> String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: flag), args.count > index + 1 else { return nil }
        return args[index + 1]
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let files = urls.filter { !$0.hasDirectoryPath }
        guard !files.isEmpty else { return }
        if let env {
            Task { @MainActor in env.workspace.open(urls: files) }
        } else {
            pendingURLs.append(contentsOf: files)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        let workspace = env?.workspace
        Task { @MainActor in
            workspace?.flushAll()
            workspace?.persistNow()
        }
    }
}
