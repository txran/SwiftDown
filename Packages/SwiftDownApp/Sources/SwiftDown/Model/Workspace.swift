import AppKit
import Foundation
import SwiftDownCore
import SwiftDownPipeline
import UniformTypeIdentifiers

/// 三态视图（FR-03）：仅源码 / 分屏 / 仅预览。快捷键 ⌘1 / ⌘⇧1 / ⌘2
enum ViewMode: String, CaseIterable, Identifiable {
    case editor, split, preview

    var id: String { rawValue }

    var label: String {
        switch self {
        case .editor: return "仅源码"
        case .split: return "分屏"
        case .preview: return "仅预览"
        }
    }

    var systemImage: String {
        switch self {
        case .editor: return "square.lefthalf.filled"
        case .split: return "rectangle.split.2x1"
        case .preview: return "square.righthalf.filled"
        }
    }

    /// 与「视图」菜单里的快捷键保持一致（状态栏 tooltip 用）
    var shortcutHint: String {
        switch self {
        case .editor: return "⌘1"
        case .split: return "⌘⇧1"
        case .preview: return "⌘2"
        }
    }
}

/// 关闭未保存标签时的确认上下文（FR-05）
struct ClosePrompt: Identifiable {
    let id = UUID()
    let tab: DocumentTab
}

/// 冲突待决上下文（FR-06 / EX-04）
struct ConflictPrompt: Identifiable {
    let id = UUID()
    let tab: DocumentTab
    let disk: DiskVersion
}

struct AlertMessage: Identifiable {
    let id = UUID()
    let title: String
    let detail: String
}

/// 工作区协调器：标签集合的唯一所有者，串起 Core 状态机 / 编辑器 / 预览 / 持久化。
@MainActor
final class Workspace: ObservableObject {

    @Published private(set) var tabs: [DocumentTab] = []
    @Published var activeTabID: UUID?
    @Published var viewMode: ViewMode = .split
    @Published var showOutline = true

    @Published var pendingClose: ClosePrompt?
    @Published var pendingConflict: ConflictPrompt?
    @Published var alertMessage: AlertMessage?

    @Published private(set) var restoredSession = false

    /// 标签拖拽排序过程中的源标签（视图层的临时状态放在这里，避免依赖 @State）
    var draggingTabID: UUID?

    let settings: AppSettings

    private let store = DiskFileStore()
    private let sessionStore: SessionStore
    private var persistWork: DispatchWorkItem?

    /// 自检专用会话目录（与用户真实会话文件隔离）
    static let selftestSessionDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("SwiftDown-selftest-session", isDirectory: true)

    /// 是否处于自检进程（自检的文件本来就在临时目录里，不能过滤）
    static let isSelfTest = CommandLine.arguments.contains("--selftest")

    /// 恢复会话时过滤掉临时目录下的路径。
    ///
    /// 为什么要过滤：临时文件没有任何人工编辑内容，恢复出来只会变成失联标签；
    /// 历史上自检把 `…/T/swiftdown-selftest-XXXX/selftest.md` 写进了真实会话，
    /// 下次启动就多出一个 selftest.md 标签，文件被删后还会走外部变更 → 冲突 → 保存失败弹窗。
    static func filterRestorablePaths(_ paths: [String], dropTemporary: Bool) -> [String] {
        guard dropTemporary else { return paths }
        return paths.filter { !isTemporaryPath($0) }
    }

    /// 路径是否落在系统临时目录内（自检产物一律在此）
    static func isTemporaryPath(_ path: String) -> Bool {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path.hasPrefix(temp)
    }

    /// >20MB 走只读源码模式（FR-01 / EX-02）
    private static let readOnlyThreshold = 20 * 1024 * 1024

    init(settings: AppSettings,
         restoreSessionOnInit: Bool = !CommandLine.arguments.contains("--selftest"),
         sessionStore: SessionStore? = nil) {
        self.settings = settings
        // 自检/出图期间会话文件落到临时目录：真实会话文件不能被工具覆盖
        self.sessionStore = sessionStore
            ?? SessionStore(directory: CommandLine.arguments.contains("--selftest")
                            ? Self.selftestSessionDirectory
                            : nil)
        // 布局来源优先级：
        //   设置了「启动时恢复上次布局」→ 上次会话的布局（无记录则用默认布局）
        //   否则 → 设置里的默认布局
        let lastLayout = ViewMode(rawValue: settings.userDefaults.string(forKey: "swiftdown.viewMode") ?? "")
        self.viewMode = settings.restoreLastLayout
            ? (lastLayout ?? settings.defaultViewMode)
            : settings.defaultViewMode
        // 自检默认从干净起点开始（否则会继承上一次跑出来的残留会话）；
        // 验证会话恢复时显式传 true。
        if restoreSessionOnInit {
            restoreSession()
        }
        registerLifecycleObservers()
    }

    /// 失焦 / 退出前强制落盘（FR-04 验收：切到其他应用再切回，磁盘内容与编辑器一致）
    private func registerLifecycleObservers() {
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.flushAll() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.flushAll() }
        }
    }

    /// 标签拖拽排序（FR-05）
    func moveTab(_ draggedID: UUID, before targetID: UUID) {
        guard let from = tabs.firstIndex(where: { $0.id == draggedID }),
              from != tabs.firstIndex(where: { $0.id == targetID }) else { return }
        let tab = tabs.remove(at: from)
        if let to = tabs.firstIndex(where: { $0.id == targetID }) {
            tabs.insert(tab, at: to)
        } else {
            tabs.append(tab)
        }
        schedulePersist()
    }

    var activeTab: DocumentTab? {
        guard let id = activeTabID else { return tabs.first }
        return tabs.first { $0.id == id } ?? tabs.first
    }

    // MARK: - 打开

    func open(urls: [URL]) {
        for url in urls { open(url: url) }
    }

    func open(url: URL) {
        let target = url.standardizedFileURL

        // FR-01：重复打开同一文件 → 聚焦已有标签，不新建
        if let existing = tabs.first(where: { $0.url.standardizedFileURL == target }) {
            activate(existing)
            // 已经在前台时不要重复激活：每次 activate 都会让系统重新排序/重绘窗口，
            // 视觉上就是一次不必要的闪动
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            return
        }

        let size = DiskFileStore.fileSize(at: target)
        do {
            let session = try DocumentSession(url: target, store: store)
            let tab = DocumentTab(session: session,
                                  settings: settings,
                                  isReadOnly: size > Self.readOnlyThreshold)
            attach(tab)
            settings.noteOpened(target)
        } catch {
            alertMessage = AlertMessage(
                title: "无法打开文件",
                detail: "\(target.lastPathComponent)\n\(error.localizedDescription)"
            )
        }
    }

    func presentOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.markdownTypes
        panel.prompt = "打开"
        panel.message = "选择 Markdown 文件"
        if panel.runModal() == .OK {
            open(urls: panel.urls)
        }
    }

    static var markdownTypes: [UTType] {
        var types: [UTType] = []
        if let md = UTType("net.daringfireball.markdown") { types.append(md) }
        types.append(.plainText)
        return types
    }

    private func attach(_ tab: DocumentTab) {
        tab.onStateChange = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.tabStateDidChange(tab)
        }
        tab.onError = { [weak self] error in
            guard let self else { return }
            self.present(error: error, tab: tab)
        }
        tabs.append(tab)
        activeTabID = tab.id
        schedulePersist()
    }

    private func tabStateDidChange(_ tab: DocumentTab) {
        // 冲突**不自动**弹三选一 sheet：
        // 1) 自动弹窗会与「保存失败」alert 抢同一层的 presentation，
        //    SwiftUI 在 macOS 上会反复重试呈现，实测表现为窗口转圈、点不动（假死）；
        // 2) 冲突用文档横幅常驻提示更合适，用户主动点「处理冲突」才需要阻断式交互。
        schedulePersist()
    }

    private func present(error: CoreError, tab: DocumentTab) {
        switch error {
        case .saveFailed(let reason):
            // 冲突态已有横幅，不再叠加弹窗（弹窗风暴会拖死主线程）
            if case .conflict = tab.state { return }
            showAlert(title: "保存失败",
                      detail: "\(tab.displayName)\n\(reason)\n\n内存中的修改已保留，可重试保存或另存为。")
        case .loadFailed(let reason):
            showAlert(title: "读取失败", detail: reason)
        case .invalidTransition:
            break
        }
    }

    /// 弹窗去重：同一条消息不重复赋值。
    /// 每次赋值都换 `id`，SwiftUI 会 dismiss + 重新 present，连续事件下就是不停重建。
    private func showAlert(title: String, detail: String) {
        if alertMessage?.title == title, alertMessage?.detail == detail { return }
        alertMessage = AlertMessage(title: title, detail: detail)
    }

    // MARK: - 激活与切换

    func activate(_ tab: DocumentTab) {
        guard activeTabID != tab.id else { return }
        // FR-04：切标签前强制落盘（不阻塞切换，落盘失败会保留脏态并提示）
        if let current = activeTab, current.id != tab.id {
            current.flush()
        }
        activeTabID = tab.id
        tab.focusedLine = tab.focusedLine  // 触发预览重新对齐
        schedulePersist()
    }

    func activateNext() {
        guard tabs.count > 1, let current = activeTab,
              let index = tabs.firstIndex(where: { $0.id == current.id }) else { return }
        activate(tabs[(index + 1) % tabs.count])
    }

    func activatePrevious() {
        guard tabs.count > 1, let current = activeTab,
              let index = tabs.firstIndex(where: { $0.id == current.id }) else { return }
        activate(tabs[(index - 1 + tabs.count) % tabs.count])
    }

    // MARK: - 关闭

    func requestClose(_ tab: DocumentTab) {
        guard tab.session.requiresCloseConfirmation else {
            performClose(tab)
            return
        }
        if case .conflict(let disk) = tab.state {
            pendingConflict = ConflictPrompt(tab: tab, disk: disk)
            return
        }
        pendingClose = ClosePrompt(tab: tab)
    }

    func confirmCloseSaving(_ prompt: ClosePrompt) {
        let tab = prompt.tab
        tab.saveNow()
        if tab.session.requiresCloseConfirmation {
            alertMessage = AlertMessage(
                title: "保存失败，标签未关闭",
                detail: "\(tab.displayName)\n内存中的修改已保留，请处理后重试。"
            )
        } else {
            performClose(tab)
        }
        pendingClose = nil
    }

    func confirmCloseDiscarding(_ prompt: ClosePrompt) {
        performClose(prompt.tab)
        pendingClose = nil
    }

    func cancelClose() {
        pendingClose = nil
    }

    private func performClose(_ tab: DocumentTab) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tab.shutdown()
        tabs.remove(at: index)

        if activeTabID == tab.id {
            if tabs.isEmpty {
                activeTabID = nil
            } else {
                activeTabID = tabs[min(index, tabs.count - 1)].id
            }
        }
        schedulePersist()
    }

    func closeOthers(than tab: DocumentTab) {
        for other in tabs where other.id != tab.id {
            requestClose(other)
        }
    }

    func closeAll() {
        for tab in tabs {
            requestClose(tab)
        }
    }

    // MARK: - 保存

    func saveActive() {
        activeTab?.saveNow()
    }

    func saveAll() {
        for tab in tabs { tab.saveNow() }
    }

    /// 应用失焦 / 退出前的强制落盘（FR-04）
    func flushAll() {
        for tab in tabs { tab.flush() }
        persistNow()
    }

    // MARK: - 冲突解决（FR-06）

    /// 冲突决策的落点是**标签**，不是弹窗。
    ///
    /// 之前只在 `pendingConflict != nil` 时才生效，导致「横幅入口 / 自检 / 任何未弹窗路径」
    /// 调进来都是空操作——冲突永远解不掉，标签一直冻结。
    func resolveConflict(_ choice: ConflictChoice, for tab: DocumentTab) {
        tab.resolveConflict(choice)
        if pendingConflict?.tab.id == tab.id { pendingConflict = nil }
        if case .clean = tab.state {
            settings.noteOpened(tab.url)
        }
    }

    func resolveConflict(_ choice: ConflictChoice) {
        guard let prompt = pendingConflict else { return }
        resolveConflict(choice, for: prompt.tab)
    }

    func saveConflictCopy() {
        guard let prompt = pendingConflict else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = Self.markdownTypes
        panel.nameFieldStringValue = prompt.tab.url.deletingPathExtension().lastPathComponent + "-副本.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        resolveConflict(.saveCopy(url), for: prompt.tab)
    }

    func dismissConflict() {
        // 关闭弹窗但不做决策：标签保持冲突态（编辑冻结），可再次从横幅唤出
        pendingConflict = nil
    }

    // MARK: - 缺失文件重定位（EX-05）

    func relocate(_ tab: DocumentTab) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = Self.markdownTypes
        panel.prompt = "重新定位"
        panel.message = "选择该文档的新位置"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        tab.relocate(to: url)
        schedulePersist()
    }

    func activatePlaceholder(_ tab: DocumentTab) {
        open(url: tab.url.standardizedFileURL)
        if let index = tabs.firstIndex(where: { $0.id == tab.id }) {
            tabs.remove(at: index)
        }
        schedulePersist()
    }

    // MARK: - 会话恢复与持久化

    func restoreSession() {
        guard !restoredSession else { return }
        restoredSession = true

        let saved = sessionStore.load()
        // 只有用户选择「记住上次布局」时，会话里的布局才覆盖默认布局
        if settings.restoreLastLayout,
           let mode = saved.viewMode,
           let parsed = ViewMode(rawValue: mode) {
            viewMode = parsed
        }
        guard !saved.tabPaths.isEmpty else { return }

        for path in Self.filterRestorablePaths(saved.tabPaths, dropTemporary: !Self.isSelfTest) {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                open(url: url)
            } else {
                // EX-06：文件不存在 → 占位标签
                let session = DocumentSession.placeholder(url: url, reason: "文件不存在")
                let tab = DocumentTab(session: session, settings: settings, isReadOnly: true)
                attach(tab)
            }
        }

        if let activePath = saved.activePath,
           let tab = tabs.first(where: { $0.url.path == activePath }) {
            activeTabID = tab.id
        }
    }

    private func schedulePersist() {
        persistWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor [weak self] in self?.persistNow() }
        }
        persistWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func persistNow() {
        // 写会话时也过滤临时路径（不只依赖恢复时过滤）：
        // 否则真实进程一旦打开过临时文件，就会把幽灵标签固化进 session.json。
        let session = PersistedSession(
            tabPaths: Self.filterRestorablePaths(tabs.map { $0.url.path }, dropTemporary: !Self.isSelfTest),
            activePath: activeTab.map { Self.isSelfTest || !Self.isTemporaryPath($0.url.path) ? $0.url.path : nil } ?? nil,
            viewMode: viewMode.rawValue
        )
        sessionStore.save(session)
        settings.userDefaults.set(viewMode.rawValue, forKey: "swiftdown.viewMode")
    }

    // MARK: - 视图模式

    func setViewMode(_ mode: ViewMode) {
        viewMode = mode
        persistNow()
    }
}
