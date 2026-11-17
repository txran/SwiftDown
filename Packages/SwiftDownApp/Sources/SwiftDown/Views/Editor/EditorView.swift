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
        coordinator.tabID = tab.id
        coordinator.observeScroll()

        MarkdownHighlighter.apply(to: storage ?? NSTextStorage(), theme: theme)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        // 切换标签：**复用**同一个 NSTextView，只替换内容。
        // 此前 RootView 上挂了 `.id(tab.id)`，打开/切换文件时 SwiftUI 会销毁重建
        // 整个 NSViewRepresentable —— 新建 NSTextView + 全量布局 + 重新高亮，
        // 编辑区先出现一段空白再填字（肉眼就是「闪一下」），顺带丢掉滚动位置与撤销栈。
        if coordinator.tabID != tab.id {
            coordinator.tab = tab
            coordinator.switchDocument(to: tab)
            return
        }

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
        /// 当前视图承载的文档标识；与 tab.id 不一致即说明要换文档而不是换视图
        var tabID: UUID?
        var lastJumpToken: Int = 0
        var theme: EditorTheme
        var fontName: String
        private var highlightWork: DispatchWorkItem?
        private var scrollObserver: NSObjectProtocol?
        private var lastReportedLine = 1
        // 滚动期行号上报节流：连续滚动时每次都写 @Published 会触发整棵
        // SwiftUI 树重算（EditorView.updateNSView 每帧一次），手感变「粘」。
        private var pendingLineWork: DispatchWorkItem?
        private var pendingLine: Int?
        private var lastLineReportedAt: CFTimeInterval = 0
        private static let lineReportInterval: CFTimeInterval = 0.08

        init(tab: DocumentTab) {
            self.tab = tab
            self.parent = EditorView(tab: tab, fontSize: 13.5, fontFamily: .sfMono, showLineNumbers: true)
            let theme = EditorTheme(fontSize: 13.5, family: .sfMono)
            self.theme = theme
            self.fontName = theme.baseFont.fontName
            super.init()
        }

        /// 把同一个文本视图切到另一份文档
        func switchDocument(to tab: DocumentTab) {
            guard let textView else { return }
            // 必须先记下新文档标识：漏了这行，切走再切回时会被判定为「无需切换」，
            // 编辑区就停在上一篇内容上（自检 `FR-04 切回标签内容正确` 抓到的就是这个）。
            tabID = tab.id
            highlightWork?.cancel()
            pendingLineWork?.cancel()
            pendingLine = nil
            revision = tab.revision
            lastJumpToken = tab.jumpToken
            lastReportedLine = 1

            // 复用同一个 NSTextView 后，撤销栈会跨文档残留：
            // 不清空的话，在新文档里按 ⌘Z 会把上一篇的内容撤回来（等于串档写坏文件）。
            textView.undoManager?.removeAllActions()

            textView.replaceEntireText(with: tab.text, theme: theme)
            if let storage = textView.textStorage {
                MarkdownHighlighter.apply(to: storage, theme: theme)
            }
            textView.isEditable = !tab.isReadOnly && tab.session.isEditable
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.needsDisplay = true

            ruler?.invalidateLineIndex()
            ruler?.needsDisplay = true
            scrollView?.contentView.scroll(to: .zero)
            if let clip = scrollView?.contentView { scrollView?.reflectScrolledClipView(clip) }
        }

        func teardown() {
            highlightWork?.cancel()
            pendingLineWork?.cancel()
            if let scrollObserver {
                NotificationCenter.default.removeObserver(scrollObserver)
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
                    guard let self, let textView = self.textView else { return }
                    let line = textView.topVisibleLine
                    if line != self.lastReportedLine {
                        self.lastReportedLine = line
                        self.reportLineThrottled(line)
                    }
                    self.ruler?.needsDisplay = true
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
            guard let textView else { return }
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
            // 小文档全量刷，大文档只刷可见区域（±4KB），保证按键不进 GC 抖动
            if storage.length <= 300_000 {
                MarkdownHighlighter.apply(to: storage, theme: theme)
            } else {
                let visible = textView.visibleRect
                let glyphRangeStart = textView.characterIndexForInsertion(at: NSPoint(x: 0, y: visible.minY))
                MarkdownHighlighter.apply(to: storage,
                                          theme: theme,
                                          limitTo: NSRange(location: max(0, glyphRangeStart), length: 4096))
            }
            textView.needsDisplay = true
            ruler?.needsDisplay = true
        }
    }
}
