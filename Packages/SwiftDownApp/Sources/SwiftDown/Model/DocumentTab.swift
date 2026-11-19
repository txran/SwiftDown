import Foundation
import SwiftDownCore
import SwiftDownPipeline

/// 查找栏叠加在编辑器上的状态：全部命中高亮 + 当前命中跳转。
struct SearchOverlay: Equatable {
    var ranges: [NSRange] = []
    var current: NSRange?
    /// 需要滚动到该处时才非空（上下切换命中 / 新查询落在第一处）
    var jump: NSRange?
    /// 每次应用自增：同样的区间重复应用也必须让编辑器重画
    var token: Int = 0

    static let none = SearchOverlay()
}

/// 编辑器桥：查找替换必须走 `NSTextView` 的标准编辑路径。
///
/// 为什么不让模型层直接改字符串再让编辑器整体重载：`insertText(_:replacementRange:)`
/// 会顺带完成撤销注册、委托通知、选区维护。绕过它自己改 model，用户按 ⌘Z 撤不回来，
/// 滚动位置也会被重载冲掉。
@MainActor
protocol EditorBridge: AnyObject {
    func replaceSearchMatch(range: NSRange, with text: String) -> Bool
    func replaceSearchMatches(ranges: [NSRange], with text: String) -> Int
}

/// 单个文档标签的视图模型：DocumentSession 的 ObservableObject 包装 + 解析管线。
///
/// 职责边界：
/// - 状态机与落盘全部委托 Core 层 `DocumentSession`（单一事实源）
/// - 本层只做「事实源 → SwiftUI 可观察对象」的投影，以及解析/监控的编排
@MainActor
final class DocumentTab: ObservableObject, Identifiable {

    let id = UUID()
    let session: DocumentSession

    /// 编辑器内容（与 session.buffer 保持同步）
    @Published private(set) var text: String
    @Published private(set) var state: DocState
    @Published private(set) var ast: MarkdownAST = .empty

    /// 程序化改写正文时自增。编辑器据此判断「是外部改写还是自己敲的」，
    /// 避免每次按键都做一次全文字符串比较（大文档下这是实打实的开销）。
    @Published private(set) var revision: Int = 0

    /// >20MB 只读源码模式（FR-01 / EX-02）
    let isReadOnly: Bool

    /// 最近一次解析耗时（ms），状态栏展示，用于性能回归肉眼监控
    @Published private(set) var lastParseMilliseconds: Double = 0
    /// 解析失败降级标记（EX-08）
    @Published private(set) var parseFailed = false
    /// 后台解析进行中（大纲据此显示「解析中…」而不是「没有标题」）
    @Published private(set) var isParsing = false

    /// 编辑器可见区域的当前行（1-based），驱动预览按标题对齐滚动（FR-03）
    @Published var focusedLine: Int = 1

    /// 用编辑器快捷键触发预览滚动（大纲点击等）时自增
    @Published private(set) var scrollRequestToken = 0
    @Published private(set) var scrollRequestLine = 0

    /// 预览已对齐的锚点行（避免同一标题反复滚动造成抖动）
    var lastAlignedAnchorLine: Int = -1

    /// 查找栏叠加状态。编辑器在 updateNSView 里按 `token` 变化应用，
    /// 不通过参数透传，避免把查找状态塞进 EditorView 的初始化签名。
    @Published private(set) var searchOverlay = SearchOverlay.none

    /// 编辑器桥：EditorView 挂载时注入；仅预览模式下为 nil（替换退化为改模型）
    weak var editorBridge: EditorBridge?

    private var watcher: FileWatcher?
    private var parseGeneration = 0
    private var parseWork: DispatchWorkItem?

    /// 状态变化回调（Workspace 用于监听冲突产生）
    var onStateChange: (() -> Void)?
    /// 错误回调（保存失败等 → 由 Workspace 统一弹窗）
    var onError: ((CoreError) -> Void)?

    private let settings: AppSettings
    /// 解析器是值类型且 Sendable，可安全跨队列传递
    private nonisolated let parser = SwiftMarkdownParser()

    /// 预览更新防抖（FR-03：输入停顿 200ms 后刷新）
    private static let parseDebounce: TimeInterval = 0.2
    /// 大文档阈值：超过则关闭实时预览以保证编辑手感（NFR-02）
    private static let previewLimitBytes = 2 * 1024 * 1024

    var url: URL { session.url }
    var displayName: String { session.url.lastPathComponent }
    var canPreview: Bool { !isReadOnly && text.utf8.count <= Self.previewLimitBytes }

    init(session: DocumentSession, settings: AppSettings, isReadOnly: Bool = false) {
        self.session = session
        self.settings = settings
        self.text = session.buffer
        self.state = session.state
        self.isReadOnly = isReadOnly

        // Core 层事件在主线程产生；这里统一 hop 回主 actor，事件顺序由 actor 队列保证
        session.onEvent = { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }

        startWatching()
        scheduleParse(immediate: true)
    }

    // MARK: - 事件

    private func handle(_ event: SessionEvent) {
        switch event {
        case .stateChanged(let newState):
            state = newState
            onStateChange?()

        case .reloadedSilently:
            // 静默重载：正文与撤销栈一起重置，编辑器需整体替换
            adoptText(session.buffer)

        case .saved:
            watcher?.noteSelfWrite(content: session.buffer)

        case .error(let error):
            onError?(error)
        }
    }

    /// 把 Core 的权威状态同步到视图模型。
    /// Core 通过 onEvent 异步投递事件，而用户动作后的 UI 反馈不能等一个事件循环，
    /// 因此凡是「用户主动触发的状态迁移」都在同步路径上补一次对齐。
    private func syncState() {
        if state != session.state {
            state = session.state
            onStateChange?()
        }
    }

    /// 标签关闭时释放资源
    func shutdown() {
        parseWork?.cancel()
        watcher?.stop()
        watcher = nil
        session.onEvent = nil
    }

    // MARK: - 编辑入口

    func userDidEdit(_ newText: String) {
        guard !isReadOnly else { return }
        guard session.isEditable else {
            // 冲突/失联态冻结编辑：把编辑器内容拉回事实源，避免分叉
            adoptText(session.buffer)
            return
        }
        session.applyEdit(newText)
        text = newText
        syncState()
        scheduleParse()
    }

    /// 程序化替换（重载、冲突采用磁盘版、撤销跨会话等）
    private func adoptText(_ newText: String) {
        text = newText
        revision += 1
        scheduleParse(immediate: true)
    }

    func saveNow() {
        guard !isReadOnly else { return }
        session.saveNow(trigger: .manual)
        syncState()
    }

    /// 切标签/失焦前的强制落盘（FR-04）
    func flush() {
        guard !isReadOnly else { return }
        session.flushBeforeDeactivation()
    }

    func resolveConflict(_ choice: ConflictChoice) {
        session.resolveConflict(choice)
        text = session.buffer
        syncState()
        revision += 1
        if case .clean = session.state {
            startWatching()
            scheduleParse(immediate: true)
        }
    }

    func relocate(to newURL: URL) {
        do {
            try session.relocate(to: newURL)
            adoptText(session.buffer)
            startWatching()
            settings.noteOpened(newURL)
        } catch {
            onError?(.loadFailed(reason: String(describing: error)))
        }
    }

    /// 占位标签激活（EX-06）
    func activate(url newURL: URL, store: FileStoring) {
        do {
            try session.activate(url: newURL, store: store)
            adoptText(session.buffer)
            startWatching()
            settings.noteOpened(newURL)
        } catch {
            onError?(.loadFailed(reason: String(describing: error)))
        }
    }

    /// 大纲点击 / 编辑区光标移动触发的预览滚动
    func requestScroll(toLine line: Int) {
        scrollRequestLine = line
        scrollRequestToken += 1
    }

    /// 大纲点击触发的编辑区跳转（FR-09：点击后编辑区与预览区同时滚到该标题）
    @Published private(set) var jumpToken = 0
    @Published private(set) var jumpLine = 0

    func requestJump(toLine line: Int) {
        jumpLine = line
        jumpToken += 1
        requestScroll(toLine: line)
    }

    // MARK: - 解析

    private func scheduleParse(immediate: Bool = false) {
        parseWork?.cancel()
        let snapshot = text
        guard canPreview else {
            ast = .empty
            isParsing = false
            return
        }
        parseGeneration += 1
        let generation = parseGeneration
        let parser = self.parser
        isParsing = true

        let work = DispatchWorkItem { [weak self] in
            // 后台阶段只做纯解析，不触碰任何 actor 隔离状态
            var parsed: MarkdownAST?
            var elapsed: Double = 0
            let started = Date()
            do {
                parsed = try parser.parse(snapshot)
                elapsed = Date().timeIntervalSince(started) * 1000
            } catch {
                parsed = nil
            }

            Task { @MainActor [weak self] in
                guard let self, generation == self.parseGeneration else { return }
                self.isParsing = false
                if let parsed {
                    self.ast = parsed
                    self.lastParseMilliseconds = elapsed
                    self.parseFailed = false
                } else {
                    self.ast = .empty
                    self.parseFailed = true
                }
            }
        }
        parseWork = work
        if immediate {
            DispatchQueue.global(qos: .userInitiated).async(execute: work)
        } else {
            DispatchQueue.global(qos: .userInitiated)
                .asyncAfter(deadline: .now() + Self.parseDebounce, execute: work)
        }
    }

    // MARK: - 监控

    private func startWatching() {
        watcher?.stop()
        watcher = nil
        guard isEditableState else { return }
        watcher = FileWatcher(url: session.url, content: session.buffer) { [weak self] event in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.session.externalChange(event)
                switch event {
                case .renamed(let newURL):
                    self.objectWillChange.send()
                    self.startWatching()
                    self.settings.noteOpened(newURL)
                case .deleted:
                    self.watcher?.stop()
                    self.watcher = nil
                case .contentChanged:
                    break
                }
            }
        }
    }

    private var isEditableState: Bool {
        switch state {
        case .clean, .dirty: return true
        case .conflict, .missing, .placeholder: return false
        }
    }

    // MARK: - 查找替换

    /// 当前是否允许改动正文（只读大文件 / 冲突 / 失联 / 占位 都拒绝）
    var canEdit: Bool { !isReadOnly && session.isEditable }

    func applySearchOverlay(ranges: [NSRange], current: NSRange?, jump: Bool) {
        var overlay = SearchOverlay()
        overlay.ranges = ranges
        overlay.current = current
        overlay.jump = jump ? current : nil
        overlay.token = searchOverlay.token &+ 1
        searchOverlay = overlay
    }

    func clearSearchOverlay() {
        guard !searchOverlay.ranges.isEmpty
                || searchOverlay.current != nil
                || searchOverlay.jump != nil else { return }
        var overlay = SearchOverlay.none
        overlay.token = searchOverlay.token &+ 1
        searchOverlay = overlay
    }

    /// 替换单处。有编辑器时走标准编辑路径（可撤销、委托与状态机自动同步）；
    /// 仅预览模式下退化为直接改模型。
    func replaceText(in range: NSRange, with replacement: String) -> Bool {
        guard canEdit else { return false }
        if let bridge = editorBridge {
            return bridge.replaceSearchMatch(range: range, with: replacement)
        }
        let ns = text as NSString
        guard range.location >= 0, range.length >= 0,
              range.location + range.length <= ns.length else { return false }
        userDidEdit(ns.replacingCharacters(in: range, with: replacement))
        return true
    }

    /// 全部替换。返回实际替换处数（0 表示无变化）。
    func replaceAllText(in ranges: [NSRange], with replacement: String) -> Int {
        guard canEdit, !ranges.isEmpty else { return 0 }
        if let bridge = editorBridge {
            return bridge.replaceSearchMatches(ranges: ranges, with: replacement)
        }
        let ns = NSMutableString(string: text)
        var applied = 0
        // 从后往前改：前面的偏移不受影响，不需要逐次校正区间
        for range in ranges.sorted(by: { $0.location > $1.location }) {
            guard range.location >= 0, range.location + range.length <= ns.length else { continue }
            ns.replaceCharacters(in: range, with: replacement)
            applied += 1
        }
        if applied > 0 { userDidEdit(ns as String) }
        return applied
    }

    // MARK: - 统计

    /// 逻辑行数（与编辑器行号同口径：末尾换行不额外算一行，
    /// 否则状态栏会出现「行 1/17」而标尺最大只到 16 的自相矛盾）
    var lineCount: Int {
        guard !text.isEmpty else { return 1 }
        var count = 1
        var endsWithNewline = false
        for ch in text {
            if ch == "\n" {
                count += 1
                endsWithNewline = true
            } else {
                endsWithNewline = false
            }
        }
        return endsWithNewline ? count - 1 : count
    }

    var characterCount: Int {
        text.count
    }

    /// 字数：CJK 按字计 + 拉丁按词计（状态栏口径，非编辑器级别的精确分词）
    var wordCount: Int {
        var words = 0
        var inLatinWord = false
        for scalar in text.unicodeScalars {
            if (0x4E00...0x9FFF).contains(scalar.value) {
                words += 1
                inLatinWord = false
            } else if CharacterSet.alphanumerics.contains(scalar) {
                if !inLatinWord { words += 1; inLatinWord = true }
            } else {
                inLatinWord = false
            }
        }
        return words
    }
}
