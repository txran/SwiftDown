import AppKit
import SwiftUI

/// 源码编辑器视图：NSTextView(TextKit 2) 的 SwiftUI 封装。
///
/// 与 SwiftUI 的同步策略（关键设计，见设计文档 §4.4）：
/// - 用户输入：编辑器 → tab.userDidEdit → Core 状态机，SwiftUI 不回头改写编辑器
/// - 程序化改写（重载/冲突/恢复）：tab.revision 自增 → 这里整体替换文本
/// 用 revision 而非字符串比较，避免每次按键做 O(n) 全量比对。
struct EditorView: NSViewRepresentable {

    @ObservedObject var tab: DocumentTab
    let fontSize: CGFloat
    let fontFamily: EditorFontFamily
    let showLineNumbers: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(tab: tab)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none
        scrollView.contentView.postsBoundsChangedNotifications = true

        let theme = ThemeCache.shared.theme(fontSize: fontSize, family: fontFamily)
        ThemeCache.shared.theme = theme

        let textView = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        textView.font = theme.baseFont
        textView.textColor = theme.textColor
        textView.typingAttributes = theme.baseAttributes
        textView.delegate = context.coordinator

        let coordinator = context.coordinator
        textView.onTextChange = { [weak coordinator] text in
            coordinator?.handleTextChange(text)
        }
        textView.onLineChange = { [weak coordinator] line in
            coordinator?.handleLineChange(line)
        }

        let storage = textView.textStorage
        textView.string = tab.text
        if let storage {
            storage.setAttributes(theme.baseAttributes, range: NSRange(location: 0, length: storage.length))
            storage.addAttribute(.paragraphStyle,
                                 value: theme.paragraphStyle,
                                 range: NSRange(location: 0, length: storage.length))
        }

        scrollView.documentView = textView

        let ruler = LineNumberRulerView(scrollView: scrollView, textView: textView, theme: theme)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = showLineNumbers
        scrollView.rulersVisible = showLineNumbers

        coordinator.textView = textView
        coordinator.ruler = ruler
        coordinator.scrollView = scrollView
        coordinator.revision = tab.revision
        coordinator.observeScroll()

        if let storage {
            if storage.length <= MarkdownHighlighter.fullScanThreshold {
                MarkdownHighlighter.applyInitial(to: storage, in: textView, theme: theme)
                coordinator.lastHighlightedVisible = MarkdownHighlighter.visibleRange(in: textView)
            } else {
                // 大文档：先让正文上屏，高亮推到下一轮 runloop（首次写属性有一次性索引开销）
                DispatchQueue.main.async { [weak coordinator] in
                    coordinator?.applyVisibleRefresh()
                }
            }
        }
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        let tabChanged = coordinator.tab !== tab
        coordinator.parent = self
        coordinator.tab = tab
        guard let textView = coordinator.textView else { return }

        // 字体/字号变化 → 重建主题并全量重刷
        let desired = ThemeCache.shared.theme(fontSize: fontSize, family: fontFamily)
        if coordinator.theme.baseFont.pointSize != desired.baseFont.pointSize
            || coordinator.fontName != desired.baseFont.fontName {
            coordinator.theme = desired
            ThemeCache.shared.theme = desired
            coordinator.ruler?.theme = desired
            textView.font = desired.baseFont
            textView.textColor = desired.textColor
            textView.typingAttributes = desired.baseAttributes
            if let storage = textView.textStorage {
                MarkdownHighlighter.apply(to: storage, theme: desired)
            }
        }

        // 切文档：复用同一个编辑器实例，只把内容换掉（见 adopt）。
        // 放在主题同步之后，保证新文档第一次绘制就用的是当前字号/字体。
        if tabChanged {
            coordinator.adopt(tab)
        }

        // 行号开关
        if scrollView.hasVerticalRuler != showLineNumbers {
            scrollView.hasVerticalRuler = showLineNumbers
            scrollView.rulersVisible = showLineNumbers
        }

        // 只读 / 编辑冻结
        let editable = !tab.isReadOnly && tab.session.isEditable
        if textView.isEditable != editable {
            textView.isEditable = editable
        }

        // 大纲点击 → 编辑区跳转
        if coordinator.lastJumpToken != tab.jumpToken {
            coordinator.lastJumpToken = tab.jumpToken
            textView.scrollToLine(tab.jumpLine)
        }

        // 程序化改写
        if coordinator.revision != tab.revision {
            coordinator.revision = tab.revision
            let selection = textView.selectedRange()
            textView.replaceEntireText(with: tab.text, theme: coordinator.theme)
            MarkdownHighlighter.apply(to: textView.textStorage ?? NSTextStorage(), theme: coordinator.theme)
            let limit = (tab.text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selection.location, limit), length: 0))
            coordinator.ruler?.invalidateLineIndex()
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {

        var parent: EditorView
        var tab: DocumentTab
        weak var textView: MarkdownTextView?
        weak var ruler: LineNumberRulerView?
        weak var scrollView: NSScrollView?

        var revision: Int = -1
        var lastJumpToken: Int = 0
        var theme: EditorTheme
        var fontName: String
        private var highlightWork: DispatchWorkItem?
        /// 换文档期间置位：此时任何「读光标/滚动位置 → 写 tab.focusedLine」都会
        /// 变成在 SwiftUI 布局期修改 @Published，把布局打回循环
        /// （上一轮就是这样让窗口显示动画中断、alpha 卡在 0 的）。
        private var isAdopting = false
        private var scrollObserver: NSObjectProtocol?
        private var lastReportedLine = 1
        // 滚动期行号上报节流：连续滚动时每次都写 @Published 会触发整棵
        // SwiftUI 树重算（EditorView.updateNSView 每帧一次），手感变「粘」。
        private var pendingLineWork: DispatchWorkItem?
        private var pendingLine: Int?
        private var lastLineReportedAt: CFTimeInterval = 0
        private static let lineReportInterval: CFTimeInterval = 0.08

        /// 上次高亮过的可见区（大文档只刷可见区时用来避免重复刷）
        var lastHighlightedVisible: NSRange?
        private var visibleRefreshWork: DispatchWorkItem?

        init(tab: DocumentTab) {
            self.tab = tab
            self.parent = EditorView(tab: tab, fontSize: 13.5, fontFamily: .sfMono, showLineNumbers: true)
            let theme = EditorTheme(fontSize: 13.5, family: .sfMono)
            self.theme = theme
            self.fontName = theme.baseFont.fontName
            super.init()
        }

        func teardown() {
            highlightWork?.cancel()
            pendingLineWork?.cancel()
            visibleRefreshWork?.cancel()
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
            }
        }

        // MARK: 大文档的可见区高亮补刷
        //
        // 首次装载/换文档时大文档只刷了首屏（全文扫描实测 2.5s，会把主线程按死），
        // 滚到下面如果不补，用户看到的是一堆没有语法色的纯文本。

        private func scheduleVisibleRefreshIfNeeded() {
            guard let textView, let storage = textView.textStorage,
                  storage.length > MarkdownHighlighter.fullScanThreshold else { return }
            let range = MarkdownHighlighter.visibleRange(in: textView)
            if let last = lastHighlightedVisible,
               abs(last.location - range.location) < MarkdownHighlighter.visiblePadding / 2 { return }
            visibleRefreshWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.applyVisibleRefresh() }
            }
            visibleRefreshWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }

        func applyVisibleRefresh() {
            guard let textView, let storage = textView.textStorage, !isAdopting,
                  storage.length > MarkdownHighlighter.fullScanThreshold else { return }
            let range = MarkdownHighlighter.visibleRange(in: textView)
            lastHighlightedVisible = range
            MarkdownHighlighter.apply(to: storage, theme: theme, limitTo: range)
            textView.needsDisplay = true
        }

        /// 切换到另一个文档标签（打开新文件 / 点标签 / 快捷键轮转）。
        ///
        /// 关键：**不重建视图**。外层 `RootView` 曾经用 `.id(tab.id)` 强制重建整棵
        /// 编辑区，AppKit 视图会在「旧的已拆、新的未挂」之间漏出一帧空白，
        /// 表现为打开文件时闪一下（切标签同理，只是幅度大小不同）。
        /// 这里改成与 TextEdit / VS Code 一致的做法：编辑器实例存活，
        /// 只替换 textStorage 内容，并把瞬态状态（撤销栈、选区、滚动）重置。
        func adopt(_ newTab: DocumentTab) {
            tab = newTab
            revision = newTab.revision
            // 跨文档的跳转令牌没有可比性，不同步会让新文档被误判成「要跳转」
            lastJumpToken = newTab.jumpToken

            guard let textView else { return }

            // 换内容 + 复位滚动期间屏蔽「位置 → 状态」的回写：
            // 这一帧正处在 SwiftUI 布局期，同步写 @Published 会把布局打回循环。
            isAdopting = true

            OpenTrace.mark("adopt 开始 chars=\((newTab.text as NSString).length)")

            textView.replaceEntireText(with: newTab.text, theme: theme)
            OpenTrace.mark("replaceEntireText 完成")

            // 撤销栈必须按文档隔离。旧实现靠视图重建天然清空，
            // 复用后若不显式清，在新文档里按 ⌘Z 会撤销出上一个文档的内容。
            textView.undoManager?.removeAllActions()

            textView.setSelectedRange(NSRange(location: 0, length: 0))

            // 顺序很关键：**先**让行号栏按新文档的行数（位数）算好宽度，
            // **再**布局，clipView 才会扣掉新的标尺宽度，最后文本视图才能贴准。
            // 反过来（先布局再改标尺）会拿到按旧标尺算的宽度，
            // 标尺随后变宽就把首行压住 —— 自检里有一条断言专盯这个。
            ruler?.prepareForNewDocument()
            OpenTrace.mark("prepareForNewDocument 完成")

            if let scrollView {
                scrollView.contentView.scroll(to: .zero)
                scrollView.reflectScrolledClipView(scrollView.contentView)
                scrollView.layoutSubtreeIfNeeded()
                OpenTrace.mark("layoutSubtreeIfNeeded 完成")
                let clipWidth = scrollView.contentView.frame.width
                if clipWidth > 0, abs(textView.frame.width - clipWidth) > 0.5 {
                    textView.setFrameSize(NSSize(
                        width: clipWidth,
                        height: max(textView.frame.height, scrollView.contentView.frame.height)))
                }
            }

            // 高亮放在滚动复位之后：大文档只刷首屏可见区，这里拿到的才是最终可视位置。
            //
            // 大文档的关键取舍：TextKit 2 对超长文本**首次**写布局属性有一次性索引开销
            // （实测 330 万字符约 220ms，同范围第二次只需 0.04ms），同步做会把「打开文件」
            // 拖到几百毫秒、用户看到的是空白窗口。这里让正文先上屏（约 17ms），
            // 高亮推到下一轮 runloop —— 用户看到的顺序变成「内容立刻出现 → 语法色紧跟着上」。
            if let storage = textView.textStorage {
                if storage.length <= MarkdownHighlighter.fullScanThreshold {
                    MarkdownHighlighter.applyInitial(to: storage, in: textView, theme: theme)
                    lastHighlightedVisible = MarkdownHighlighter.visibleRange(in: textView)
                    OpenTrace.mark("MarkdownHighlighter 同步完成")
                } else {
                    lastHighlightedVisible = nil
                    DispatchQueue.main.async { [weak self] in
                        self?.applyVisibleRefresh()
                    }
                    OpenTrace.mark("MarkdownHighlighter 已推迟（大文档）")
                }
            }

            textView.needsDisplay = true
            ruler?.needsDisplay = true

            lastReportedLine = 1
            isAdopting = false

            // 行号状态推到下一轮 runloop 再对齐：布局期写 @Published 会把布局打回循环
            DispatchQueue.main.async { [weak self, weak newTab] in
                guard let self, let newTab, self.tab === newTab else { return }
                if newTab.focusedLine != 1 { newTab.focusedLine = 1 }
            }
        }

        func observeScroll() {
            guard let scrollView else { return }
            // 通知本身就派发在主线程（queue: .main），这里直接同步处理。
            // 早期版本再套一层 Task { @MainActor }，滚动时会在主队列堆积大量任务，
            // 表现为滚动「粘手」。
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let textView = self.textView, !self.isAdopting else { return }
                    let line = textView.topVisibleLine
                    if line != self.lastReportedLine {
                        self.lastReportedLine = line
                        self.reportLineThrottled(line)
                    }
                    self.ruler?.needsDisplay = true
                    self.scheduleVisibleRefreshIfNeeded()
                }
            }
        }

        // MARK: 编辑回调

        func handleTextChange(_ text: String) {
            tab.userDidEdit(text)
            ruler?.invalidateLineIndex()
            scheduleHighlight()
        }

        func handleLineChange(_ line: Int) {
            lastReportedLine = line
            reportLine(line)
        }

        /// 滚动引起的行号变化走节流；光标移动/点击立即生效（见 textViewDidChangeSelection）
        private func reportLineThrottled(_ line: Int) {
            let now = CACurrentMediaTime()
            if now - lastLineReportedAt >= Self.lineReportInterval {
                lastLineReportedAt = now
                pendingLine = nil
                reportLine(line)
                return
            }
            pendingLine = line
            pendingLineWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, let pending = self.pendingLine else { return }
                    self.pendingLine = nil
                    self.lastLineReportedAt = CACurrentMediaTime()
                    self.reportLine(pending)
                }
            }
            pendingLineWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.lineReportInterval, execute: work)
        }

        private func reportLine(_ line: Int) {
            if tab.focusedLine != line {
                tab.focusedLine = line
            }
        }

        // MARK: NSTextViewDelegate

        func textViewDidChangeSelection(_ notification: Notification) {
            // 换文档时会主动重设选区，那次回调不是用户行为，不能回写 focusedLine
            guard let textView, !isAdopting else { return }
            textView.typingAttributes = theme.baseAttributes
            let line = textView.currentLine
            if line != lastReportedLine {
                lastReportedLine = line
                reportLine(line)
            }
        }

        // MARK: 高亮

        private func scheduleHighlight() {
            highlightWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor [weak self] in
                    self?.applyHighlight()
                }
            }
            highlightWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }

        private func applyHighlight() {
            guard let textView, let storage = textView.textStorage else { return }
            // 小文档全文刷，大文档只刷可见区：全文扫描 330 万字符实测 2.5s，
            // 每敲一个字都付这个代价是不可接受的。
            if storage.length <= MarkdownHighlighter.fullScanThreshold {
                MarkdownHighlighter.apply(to: storage, theme: theme)
                lastHighlightedVisible = nil
            } else {
                let range = MarkdownHighlighter.visibleRange(in: textView)
                lastHighlightedVisible = range
                MarkdownHighlighter.apply(to: storage, theme: theme, limitTo: range)
            }
            textView.needsDisplay = true
            ruler?.needsDisplay = true
        }
    }
}
