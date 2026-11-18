import AppKit
import SwiftUI

/// 应用级依赖容器：settings 与 workspace 的生命周期由它统一持有
@MainActor
final class AppEnvironment: ObservableObject {
    let settings: AppSettings
    let workspace: Workspace

    init() {
        // 冷启动时间线基准：从这里开始，进程已经建好了 SwiftUI App 结构，
        // 后续每一步都打点，日志里出现空档时就能判断空档落在哪一段。
        LaunchProbe.mark("AppEnvironment.init 进入")
        LaunchProbe.startWatchdog()
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
        LaunchProbe.mark("AppEnvironment.init 完成（会话元信息已就位）")
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
    /// 首帧通知的订阅令牌（会话恢复在这里被触发的）
    private var firstFrameToken: NSObjectProtocol?

    /// 是否已接管 kAEOpenDocuments。自检用它防回归：这段一旦被删掉，
    /// 「打开文件闪一下」会原样回来，而且没有任何其他断言能发现。
    nonisolated(unsafe) private(set) static var didTakeOverOpenDocuments = false

    /// 抢在 SwiftUI 之前接管「打开文稿」的 Apple Event。
    ///
    /// 为什么必须抢：SwiftUI 的 `AppWindowsController.open(urls:)` 在处理外部打开事件时，
    /// 会先把当前窗口 `-[NSWindow _close]` 掉，再为文档激活窗口（调用栈实测确认）。
    /// 结果就是窗口 isVisible 从 1 掉到 0 再回来——用户看到的就是「闪一下，像关掉又重开」。
    /// 我们自己做多标签，只需要把文件塞进 Workspace，绝不能让它去关窗口。
    ///
    /// 必须装在 `applicationWillFinishLaunching`：AppKit 在启动阶段就分发 open 事件，
    /// 装晚了第一份文件还是会走 SwiftUI 那条路。
    func applicationWillFinishLaunching(_ notification: Notification) {
        LaunchProbe.mark("willFinishLaunching 进入")
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleOpenDocuments(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass),
            andEventID: AEEventID(kAEOpenDocuments)
        )
        AppDelegate.didTakeOverOpenDocuments = true
        LaunchProbe.mark("willFinishLaunching 完成（已接管 open 事件）")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchProbe.mark("didFinishLaunching")
    }

    @objc private func handleOpenDocuments(_ event: NSAppleEventDescriptor,
                                           withReplyEvent reply: NSAppleEventDescriptor) {
        var urls: [URL] = []
        if let direct = event.paramDescriptor(forKeyword: keyDirectObject) {
            for index in 1...max(1, direct.numberOfItems) {
                guard let item = direct.atIndex(index) else { continue }
                if let url = item.fileURLValue ?? URL(string: item.stringValue ?? "") {
                    urls.append(url)
                }
            }
        }
        // 必须先回复再干活：接管之后 AppKit 的默认处理不再执行，没人回复发送方
        // （访达 / `open -a`）就会一直等到超时，实测表现为 -1712、双击文件后转圈。
        // 回一个空错误列表 = 全部接收成功（真失败了才在该列表里放失败项）。
        acknowledge(reply)
        LaunchProbe.mark("open 事件：已回 reply（urls=\(urls.count)）")

        guard !urls.isEmpty else { return }
        TraceEvents.log("apple-event open \(urls.map(\.lastPathComponent)) isActive=\(NSApp.isActive ? 1 : 0)")
        if let env {
            Task { @MainActor in env.workspace.open(urls: urls) }
        } else {
            pendingURLs.append(contentsOf: urls)
        }
    }

    /// 发送方不要回复时（`descriptorType == typeNull`）不能碰 reply，否则会崩
    private func acknowledge(_ reply: NSAppleEventDescriptor) {
        guard reply.descriptorType != typeNull else { return }
        reply.setDescriptor(NSAppleEventDescriptor.list(), forKeyword: keyDirectObject)
    }

    @MainActor
    func attach(_ env: AppEnvironment) {
        guard self.env == nil else { return }
        LaunchProbe.mark("视图 onAppear → attach")
        LaunchProbe.markFirstWindowDraw()
        TraceEvents.install()
        self.env = env
        if !pendingURLs.isEmpty {
            env.workspace.open(urls: pendingURLs)
            pendingURLs.removeAll()
        }
        // 会话里的文档等首帧之后才读（见 restoreAfterFirstFrame）
        restoreAfterFirstFrame(env)
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

    /// 首帧之后再读会话里的文档。
    ///
    /// 为什么不在启动阶段读：冷启动时一次文件 `open(2)` 可能被系统拖到 5 秒以上
    /// （主线程卡在 `libsystem_kernel.__open`，跨线程采样实证）。4 个标签就是 4 个坑，
    /// 全压在启动阶段里意味着：窗口迟迟不出来，`didFinishLaunching` 也迟迟不返回，
    /// 访达 / `open -a` 投递的打开事件 30 秒等不到应答 → -1712。
    /// 现在窗口先画出来，标签随后补上（读盘本身在后台线程）。
    private func restoreAfterFirstFrame(_ env: AppEnvironment) {
        var fired = false
        let fire: @MainActor () -> Void = { [weak self] in
            guard !fired else { return }
            fired = true
            if let token = self?.firstFrameToken {
                NotificationCenter.default.removeObserver(token)
                self?.firstFrameToken = nil
            }
            LaunchProbe.mark("首帧后开始恢复会话")
            env.workspace.performSessionRestore()
        }
        firstFrameToken = NotificationCenter.default.addObserver(
            forName: NSWindow.didUpdateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { fire() }
        }
        // 兜底：窗口因故没有 didUpdate 时也别让标签永远回不来
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            MainActor.assumeIsolated { fire() }
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
        TraceEvents.log("app open urls=\(files.map(\.lastPathComponent)) isActive=\(NSApp.isActive ? 1 : 0) envReady=\(env != nil ? 1 : 0)")
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
