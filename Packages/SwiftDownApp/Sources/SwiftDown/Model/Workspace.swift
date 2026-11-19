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

    /// 查找栏状态（⌘F / ⌘⌥F）。放在 Workspace 里是因为重算需要访问标签集合，
    /// 而它自己也只在有活跃文档时有意义。
    let search = SearchController()

    private let store = DiskFileStore()
    private let sessionStore: SessionStore
    private var persistWork: DispatchWorkItem?

    /// 正在读盘中的路径（防止同一文件被并发打开两次）
    private var openingPaths: Set<String> = []

    /// 启动时会话恢复只取元信息，文档内容等首帧之后再由这里补上
    private var pendingRestore: PersistedSession?

    /// 恢复正在进行中（期间的 `open` 视为用户主动打开）
    private var restoring = false

    /// 启动阶段用户主动打开的文件（访达双击 / `open -a` 带参数）
    private var launchRequestedPath: String?

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

    /// 路径是否落在系统临时目录内（自检产物、CLI 出图、调试用文件一律在此）
    ///
    /// 注意 `/tmp` 不等于 `NSTemporaryDirectory()`：后者是 `/var/folders/…/T`。
    /// 只比 NSTemporaryDirectory 会漏掉手工放在 `/tmp` 的测试文件——
    /// 实测打开过 `/tmp/*.md` 之后，这些路径会被写进 session.json，
    /// 下次启动就恢复出几个已经不存在的标签（用户侧表现是「幽灵标签」）。
    static func isTemporaryPath(_ path: String) -> Bool {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let temp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
        if resolved.hasPrefix(temp) { return true }
        // resolvingSymlinksInPath 会把 /tmp 归一成 /private/tmp，两个前缀都判一次
        return resolved.hasPrefix("/private/tmp/") || resolved.hasPrefix("/tmp/")
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
            // 只读元信息（几百字节 JSON）：布局要在首帧前就位，否则窗口会先按默认布局
            // 画一遍再跳成上次布局。文档内容推迟到首帧之后，见 performSessionRestore()。
            prepareSessionRestore()
        }
        registerLifecycleObservers()
        configureSearch()
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
        for url in urls { noteLaunchRequest(url) }
        // 同一个 Task 里逐个 await：多文件不会被并发读盘打乱标签顺序
        Task { for url in urls { await performOpen(url) } }
    }

    func open(url: URL) {
        noteLaunchRequest(url)
        Task { await performOpen(url) }
    }

    /// 启动阶段（会话还没恢复完）用户主动打开的文件要记住：
    /// 恢复结束时不能把活跃标签强行切回「上次退出时的那份」，用户点谁就该看着谁。
    private func noteLaunchRequest(_ url: URL) {
        guard pendingRestore != nil || restoring else { return }
        launchRequestedPath = url.standardizedFileURL.path
    }

    /// 自检/工具用：等这次打开真正落地（读盘 + 挂标签）再返回
    @discardableResult
    func openAndWait(url: URL) async -> DocumentTab? {
        await performOpen(url)
    }

    /// 打开文档的唯一实现。
    ///
    /// **读盘不在主线程**。冷启动时实测过：一次文件 `open(2)` 被系统拖到 5 秒以上，
    /// 主线程卡在 `libsystem_kernel.__open`（看门狗跨线程采样确认）。会话恢复有几个文件
    /// 就是几个这样的坑，全压在主线程的启动阶段里 → 窗口迟迟不出、访达投递的打开事件
    /// 30 秒等不到应答，发送方报 -1712。现在主线程只做「挂标签」，读盘慢只表现为
    /// 内容稍后出现，窗口、事件处理都不受影响。
    @discardableResult
    private func performOpen(_ url: URL) async -> DocumentTab? {
        let target = url.standardizedFileURL
        OpenTrace.shared.begin("open \(target.lastPathComponent)（触发前 active=\(NSApp.isActive ? 1 : 0)）")

        // FR-01：重复打开同一文件 → 聚焦已有标签，不新建
        if let existing = tabs.first(where: { $0.url.standardizedFileURL == target }) {
            activate(existing)
            // 已经在前台时不要重复激活：每次 activate 都会让系统重新排序/重绘窗口，
            // 视觉上就是一次不必要的闪动
            if !NSApp.isActive { NSApp.activate(ignoringOtherApps: true) }
            return existing
        }
        // 同一个文件正在读盘中（连点两下、事件与恢复撞车）→ 不重复打开
        guard !openingPaths.contains(target.path) else { return nil }
        openingPaths.insert(target.path)
        defer { openingPaths.remove(target.path) }

        OpenTrace.mark("open 开始 \(target.lastPathComponent)")
        switch await Self.loadFromDisk(target) {
        case .loaded(let content, let bytes):
            OpenTrace.mark("读盘完成 \(bytes / 1024)KB")
            let tab = makeTab(url: target, content: content, size: bytes)
            settings.noteOpened(target)
            OpenTrace.mark("noteOpened 完成")
            return tab
        case .failed(let reason):
            alertMessage = AlertMessage(
                title: "无法打开文件",
                detail: "\(target.lastPathComponent)\n\(reason)"
            )
            return nil
        }
    }

    /// 装配并挂上一个已读出内容的标签（内存操作，不碰文件系统）
    @discardableResult
    private func makeTab(url: URL, content: String, size: Int) -> DocumentTab {
        let session = DocumentSession(url: url, content: content, store: store)
        OpenTrace.mark("DocumentSession 建立")
        let tab = DocumentTab(session: session,
                              settings: settings,
                              isReadOnly: size > Self.readOnlyThreshold)
        OpenTrace.mark("DocumentTab 构造完成")
        attach(tab)
        OpenTrace.mark("attach 完成")
        return tab
    }

    /// 读盘结果（Sendable：要从后台线程带回主线程）
    enum DiskLoad: Sendable {
        case loaded(text: String, bytes: Int)
        case failed(reason: String)
    }

    /// `nonisolated async` 不继承调用者的 actor（SE-0338），所以这里天然跑在协作线程池上
    nonisolated static func loadFromDisk(_ url: URL) async -> DiskLoad {
        let store = DiskFileStore()
        let bytes = DiskFileStore.fileSize(at: url)
        do {
            return .loaded(text: try store.load(from: url), bytes: bytes)
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return .failed(reason: reason)
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
        if search.isPresented { refreshSearch() }
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
        if search.isPresented { refreshSearch() }
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
        // 命中表是按标签算的，集合一变就得重算（否则会指向已关闭的文档）
        if search.isPresented { refreshSearch() }
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

    /// 第一段：只读会话元信息（布局 + 路径清单），不碰任何文档文件。
    ///
    /// 为什么拆两段：文档读盘在冷启动时可能被系统拖到秒级（见 `performOpen` 的注释），
    /// 4 个标签就是 4 个坑。这段留在启动阶段只会延长「窗口出现」和
    /// 「didFinishLaunching 完成」的时间，进而让访达投递的打开事件等到超时（-1712）。
    /// 元信息只有一个几百字节的 JSON，读它 <1ms，布局因此仍能在首帧前定下来。
    func prepareSessionRestore() {
        guard !restoredSession else { return }
        restoredSession = true
        let saved = sessionStore.load()
        LaunchProbe.mark("会话元信息已读取 tabs=\(saved.tabPaths.count)")
        // 只有用户选择「记住上次布局」时，会话里的布局才覆盖默认布局
        if settings.restoreLastLayout,
           let mode = saved.viewMode,
           let parsed = ViewMode(rawValue: mode) {
            viewMode = parsed
        }
        pendingRestore = saved
    }

    /// 第二段：首帧之后调用，真正把标签读出来挂上。
    func performSessionRestore() {
        Task { await restoreNow() }
    }

    /// 可等待的恢复（首帧回调与自检共用）
    func restoreNow() async {
        guard let saved = pendingRestore else { return }
        pendingRestore = nil
        let paths = Self.filterRestorablePaths(saved.tabPaths, dropTemporary: !Self.isSelfTest)
        guard !paths.isEmpty else { return }
        await restore(paths: paths, activePath: saved.activePath)
    }

    private func restore(paths: [String], activePath: String?) async {
        restoring = true
        defer { restoring = false }

        for path in paths {
            let url = URL(fileURLWithPath: path)
            if FileManager.default.fileExists(atPath: path) {
                await performOpen(url)
            } else {
                // EX-06：文件不存在 → 占位标签
                let session = DocumentSession.placeholder(url: url, reason: "文件不存在")
                let tab = DocumentTab(session: session, settings: settings, isReadOnly: true)
                attach(tab)
            }
        }

        // 用户启动时主动点开的文件优先：把它挪到最后并激活。
        // 判断依据不能用「恢复开始时 tabs 是否为空」——启动阶段用户的文件可能正好在
        // 恢复过程中读盘完成并挂上，那时快照里还是空的，恢复结束时就会把活跃标签抢回
        // 上次退出时的那份（实测：双击 A 启动，最后活跃的却是会话里的另一份）。
        if let requested = launchRequestedPath,
           let tab = tabs.first(where: { $0.url.path == requested }) {
            tabs = tabs.filter { $0.id != tab.id } + [tab]
            activeTabID = tab.id
        } else if let activePath,
                  let tab = tabs.first(where: { $0.url.path == activePath }) {
            activeTabID = tab.id
        }
        TraceEvents.log("会话恢复完成 tabs=\(tabs.count) requested=\(launchRequestedPath?.split(separator: "/").last.map(String.init) ?? "-")")
        launchRequestedPath = nil
        schedulePersist()
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

    // MARK: - 查找与替换

    private var searchRefreshWork: DispatchWorkItem?

    private func configureSearch() {
        search.onChange = { [weak self] in self?.scheduleSearchRefresh() }
        search.onJump = { [weak self] match in self?.jumpToMatch(match) }
    }

    /// 输入框每变一个字都会走到这里，节流后再真扫。
    /// 全文扫描是 O(n)（4.8MB 文档实测几十毫秒），逐键同步扫会让输入明显发滞。
    private func scheduleSearchRefresh() {
        searchRefreshWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refreshSearch() }
        }
        searchRefreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func showFind(replace: Bool = false) {
        search.showsReplace = replace
        search.isPresented = true
        refreshSearch()
    }

    func closeFind() {
        searchRefreshWork?.cancel()
        search.isPresented = false
        search.reset()
        activeTab?.clearSearchOverlay()
    }

    /// 重算命中并刷新叠加层。同步执行（自检直接调它，不依赖节流）。
    func refreshSearch() {
        guard search.isPresented else { return }
        guard let tab = activeTab else {
            search.apply(documentMatches: [], tabResults: [], error: nil)
            return
        }
        guard search.hasQuery else {
            search.apply(documentMatches: [], tabResults: [], error: nil)
            tab.clearSearchOverlay()
            return
        }
        if let error = FindEngine.validate(query: search.query, options: search.options) {
            search.apply(documentMatches: [], tabResults: [], error: error)
            tab.clearSearchOverlay()
            return
        }

        let documentMatches = FindEngine.matches(in: tab.text,
                                                 query: search.query,
                                                 options: search.options)
        var results: [TabSearchResult] = []
        if search.scope == .allTabs {
            for each in tabs {
                // 当前标签的结果已经算过，不重复扫
                let matches = each.id == tab.id
                    ? documentMatches
                    : FindEngine.matches(in: each.text, query: search.query, options: search.options)
                if !matches.isEmpty {
                    results.append(TabSearchResult(id: each.id,
                                                   name: each.displayName,
                                                   path: each.url.path,
                                                   matches: matches))
                }
            }
        }
        search.apply(documentMatches: documentMatches, tabResults: results, error: nil)
        applySearchOverlay(jumpToCurrent: true)
    }

    private func applySearchOverlay(jumpToCurrent: Bool) {
        guard let tab = activeTab else { return }
        tab.applySearchOverlay(ranges: search.documentMatches.map(\.range),
                               current: search.currentMatch?.range,
                               jump: jumpToCurrent && search.currentMatch != nil)
    }

    private func jumpToMatch(_ match: SearchMatch) {
        guard let tab = activeTab else { return }
        tab.applySearchOverlay(ranges: search.documentMatches.map(\.range),
                               current: match.range,
                               jump: true)
    }

    /// 「所有标签」结果列表点击：先切到那个标签，再跳到这一处
    func jumpToResult(tabID: UUID, match: SearchMatch) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        if tab.id != activeTabID { activate(tab) }
        refreshSearch()
        tab.applySearchOverlay(ranges: search.documentMatches.map(\.range),
                               current: match.range,
                               jump: true)
    }

    func findNext() {
        guard search.isPresented else { showFind(); return }
        search.next()
    }

    func findPrevious() {
        guard search.isPresented else { showFind(); return }
        search.previous()
    }

    func replaceCurrentMatch() {
        guard search.isPresented, search.scope == .document,
              let tab = activeTab, let match = search.currentMatch else { return }
        guard tab.canEdit else { return }
        if tab.replaceText(in: match.range, with: search.replacement) {
            // 替换后命中表已变化：重算，游标停在原位置就正好是「下一处」
            refreshSearch()
        }
    }

    func replaceAllMatches() {
        guard search.isPresented, search.scope == .document, let tab = activeTab else { return }
        let ranges = search.documentMatches.map(\.range)
        guard !ranges.isEmpty, tab.canEdit else { return }
        if tab.replaceAllText(in: ranges, with: search.replacement) > 0 {
            refreshSearch()
        }
    }

    // MARK: - 视图模式

    func setViewMode(_ mode: ViewMode) {
        viewMode = mode
        persistNow()
    }
}
