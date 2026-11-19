import AppKit
import SwiftDownEditorKit

/// 编辑器 NSTextView（TextKit 2）。
/// 只做三件 Core/UI 无关的事：把文本变化抛出去、拦截 ⌘B/⌘I、回车续列表。
final class MarkdownTextView: NSTextView {

    var onTextChange: ((String) -> Void)?
    var onLineChange: ((Int) -> Void)?
    var onScroll: ((Int) -> Void)?

    /// 程序化写入时置位，避免把「我自己改的」当成用户编辑
    private var isApplyingProgrammaticChange = false

    /// 批量编辑深度：全部替换时逐处调用 `insertText`，中间不逐次回写模型
    /// （500 处 × 每次全量同步 = 500 次字符串拷贝 + 500 次落盘调度）。
    private var batchDepth = 0

    /// 已应用的查找高亮，用于下次清除。两个引擎分开记，互不干扰。
    private var appliedSearchRangesTK2: [NSTextRange] = []
    private var appliedSearchRangesTK1: [NSRange] = []

    // MARK: - 行索引
    //
    // 滚动同步与行号标尺每秒要问几十次「这个偏移是第几行」。
    // 早期实现每次都从文档起点 while 循环数换行，是滚动卡顿的主因；
    // 这里改为缓存逻辑行起始偏移表 + 二分查找，索引仅在文本变化时重建。

    private var lineStarts: [Int] = [0]
    private var lineIndexDirty = true

    /// 行索引版本号：文本变化时递增，供标尺判断是否要重算宽度
    private(set) var lineIndexVersion: Int = 0

    /// 逻辑行总数（末尾换行不额外算一行）
    var logicalLineCount: Int {
        ensureLineIndex()
        return lineStarts.count
    }

    func ensureLineIndex() {
        guard lineIndexDirty else { return }
        let ns = string as NSString
        let length = ns.length
        var starts: [Int] = [0]
        starts.reserveCapacity(max(8, length / 60))
        var cursor = 0
        while cursor < length {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                            for: NSRange(location: cursor, length: 0))
            if lineEnd <= cursor { break }
            if lineEnd < length { starts.append(lineEnd) }
            cursor = lineEnd
        }
        lineStarts = starts
        lineIndexDirty = false
        lineIndexVersion += 1
    }

    /// 0-based UTF-16 偏移 → 1-based 行号（二分，O(log n)）
    func lineNumber(atUTF16Offset offset: Int) -> Int {
        ensureLineIndex()
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset {
                low = mid
            } else {
                high = mid - 1
            }
        }
        return low + 1
    }

    /// 是否为某逻辑行的首个字符（自动换行的续行返回 false）
    func isLogicalLineStart(_ offset: Int) -> Bool {
        ensureLineIndex()
        return lineStarts[lineNumber(atUTF16Offset: offset) - 1] == offset
    }

    /// 1-based 行号 → UTF-16 偏移（越界返回文本末尾）
    func offset(ofLine line: Int) -> Int {
        ensureLineIndex()
        guard line > 1 else { return 0 }
        let index = line - 1
        if index < lineStarts.count { return lineStarts[index] }
        return (string as NSString).length
    }

    // MARK: - 生命周期

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    /// NSTextView 内部实际走的是这个指定初始化器，必须一并覆盖
    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isRichText = false
        isEditable = true
        isSelectable = true
        allowsUndo = true
        undoManager?.levelsOfUndo = 0  // FR-04：本次会话内无上限
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        // 不用系统查找栏：它的快捷键不可改，也搜不到其他标签。
        // 应用自己实现查找栏（⌘F / ⌘⌥F，见 FindBar），这里必须关掉，
        // 否则同一条 ⌘F 会同时唤出两套 UI。
        usesFindBar = false
        isIncrementalSearchingEnabled = false
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        textContainerInset = NSSize(width: 14, height: 14)
        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        minSize = NSSize(width: 0, height: 0)
        maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textContainer?.widthTracksTextView = true
        textContainer?.lineFragmentPadding = 0
        allowsUndo = true
    }

    // MARK: - 文本变化

    override func didChangeText() {
        super.didChangeText()
        lineIndexDirty = true
        guard !isApplyingProgrammaticChange, batchDepth == 0 else { return }
        onTextChange?(string)
        reportCurrentLine()
    }

    /// 批量编辑开始：期间不逐次回写模型，结束时统一通知一次
    func beginBatchEdit() {
        batchDepth += 1
    }

    func endBatchEdit() {
        guard batchDepth > 0 else { return }
        batchDepth -= 1
        guard batchDepth == 0 else { return }
        lineIndexDirty = true
        onTextChange?(string)
        reportCurrentLine()
    }

    /// 整体替换（重载 / 冲突采用磁盘版 / 会话恢复）
    func replaceEntireText(with newText: String, theme: EditorTheme) {
        // 整体换文本后旧的命中区间全部失效，先撤掉高亮再写内容
        clearSearchHighlights()
        isApplyingProgrammaticChange = true
        let selection = selectedRange()
        let attributed = NSAttributedString(string: newText, attributes: theme.baseAttributes)
        textStorage?.setAttributedString(attributed)
        let limit = (newText as NSString).length
        setSelectedRange(NSRange(location: min(selection.location, limit), length: 0))
        isApplyingProgrammaticChange = false
        lineIndexDirty = true
        needsDisplay = true
    }

    // MARK: - 查找高亮与跳转

    /// 把当前命中滚到可见位置并选中。
    ///
    /// 不调 `makeFirstResponder`：查找时焦点还在输入框里，抢焦点会让用户
    /// 打完一个字就被踢出输入框。用系统查找指示器（`showFindIndicator`）
    /// 代替焦点，视觉上同样明确。
    func jump(to range: NSRange) {
        let length = (string as NSString).length
        guard range.location >= 0, range.location <= length else { return }
        let safe = NSRange(location: range.location,
                           length: min(range.length, length - range.location))
        setSelectedRange(safe)
        scrollRangeToVisible(safe)
        showFindIndicator(for: safe)
    }

    /// 全部命中的临时高亮。
    ///
    /// 刻意**不**写进 textStorage：那会污染撤销栈、触发 `didChangeText`，
    /// 还会被语法高亮整段覆盖。改用引擎的「临时/渲染属性」层：
    /// - TextKit 2：`NSTextLayoutManager.addRenderingAttribute`
    /// - TextKit 1：`NSLayoutManager.setTemporaryAttributes`
    ///
    /// 分流必须先问 `textLayoutManager`（判断顺序见设计文档：先 TK2 后 TK1），
    /// 反了会把这个视图静默降级成 TextKit 1。
    func applySearchHighlights(_ ranges: [NSRange], current: NSRange?) {
        clearSearchHighlights()
        let length = (string as NSString).length
        let valid = ranges.filter {
            $0.length > 0 && $0.location >= 0 && $0.location + $0.length <= length
        }
        guard !valid.isEmpty else { return }

        if let layoutManager2 = textLayoutManager {
            guard let content = layoutManager2.textContentManager else { return }
            let origin = content.documentRange.location
            for range in valid {
                let color = highlightColor(for: range, current: current)
                guard let start = content.location(origin, offsetBy: range.location),
                      let end = content.location(start, offsetBy: range.length),
                      let textRange = NSTextRange(location: start, end: end) else { continue }
                layoutManager2.addRenderingAttribute(.backgroundColor, value: color, for: textRange)
                appliedSearchRangesTK2.append(textRange)
            }
        } else if let layoutManager1 = layoutManager {
            for range in valid {
                let color = highlightColor(for: range, current: current)
                layoutManager1.setTemporaryAttributes([.backgroundColor: color],
                                                     forCharacterRange: range)
                appliedSearchRangesTK1.append(range)
            }
        }
    }

    func clearSearchHighlights() {
        if let layoutManager2 = textLayoutManager {
            for range in appliedSearchRangesTK2 {
                layoutManager2.removeRenderingAttribute(.backgroundColor, for: range)
            }
        } else if let layoutManager1 = layoutManager {
            for range in appliedSearchRangesTK1 {
                layoutManager1.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            }
        }
        appliedSearchRangesTK2.removeAll(keepingCapacity: true)
        appliedSearchRangesTK1.removeAll(keepingCapacity: true)
    }

    private func highlightColor(for range: NSRange, current: NSRange?) -> NSColor {
        // 当前命中用实色，其余压到 35%：一眼能分出「我现在在哪一处」
        range == current ? .findHighlightColor : NSColor.findHighlightColor.withAlphaComponent(0.35)
    }

    // MARK: - 替换（走标准编辑路径，撤销可回）

    /// 替换单处。`insertText(_:replacementRange:)` 是 NSTextView 的标准编辑入口：
    /// 撤销注册、委托通知、选区维护都由它完成。
    func replaceMatch(range: NSRange, with text: String) -> Bool {
        let length = (string as NSString).length
        guard range.location >= 0, range.location + range.length <= length else { return false }
        insertText(text, replacementRange: range)
        return true
    }

    /// 全部替换：倒序逐处替换，所有改动合成**一个**撤销步骤。
    func replaceMatches(ranges: [NSRange], with text: String) -> Int {
        let length = (string as NSString).length
        let valid = ranges
            .filter { $0.location >= 0 && $0.location + $0.length <= length }
            .sorted { $0.location > $1.location }
        guard !valid.isEmpty else { return 0 }

        let undo = undoManager
        undo?.beginUndoGrouping()
        beginBatchEdit()
        for range in valid {
            insertText(text, replacementRange: range)
        }
        endBatchEdit()
        undo?.endUndoGrouping()
        return valid.count
    }

    // MARK: - 语法辅助

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command,
           let chars = event.charactersIgnoringModifiers?.lowercased() {
            if chars == "b" { toggleWrap(marker: "**"); return true }
            if chars == "i" { toggleWrap(marker: "*"); return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    private func toggleWrap(marker: String) {
        let sel = selectedRange()
        let result = MarkdownSyntaxHelper.toggleWrap(text: string,
                                                     selection: sel.location..<(sel.location + sel.length),
                                                     marker: marker)
        let editRange = NSRange(location: result.range.lowerBound, length: result.range.count)
        guard shouldChangeText(in: editRange, replacementString: result.replacement) else { return }

        isApplyingProgrammaticChange = true
        textStorage?.replaceCharacters(in: editRange, with: result.replacement)
        didChangeText()
        isApplyingProgrammaticChange = false

        setSelectedRange(NSRange(location: result.newSelection.lowerBound,
                                 length: result.newSelection.count))
        onTextChange?(string)
    }

    override func insertNewline(_ sender: Any?) {
        let sel = selectedRange()
        guard sel.length == 0 else {
            super.insertNewline(sender)
            return
        }
        let ns = string as NSString
        let lineRange = ns.lineRange(for: NSRange(location: sel.location, length: 0))
        let beforeCaret = ns.substring(with: NSRange(location: lineRange.location,
                                                   length: sel.location - lineRange.location))
        if let prefix = MarkdownSyntaxHelper.listContinuation(forLine: beforeCaret) {
            insertText("\n" + prefix, replacementRange: sel)
        } else {
            super.insertNewline(sender)
        }
    }

    // MARK: - 行号上报

    /// 滚动到指定行并把光标放到行首（FR-09 大纲点击跳转）
    func scrollToLine(_ targetLine: Int) {
        let length = (string as NSString).length
        let caret = NSRange(location: min(offset(ofLine: targetLine), length), length: 0)
        setSelectedRange(caret)
        window?.makeFirstResponder(self)
        scrollRangeToVisible(NSRange(location: caret.location, length: min(1, max(0, length - caret.location))))
    }

    /// 光标所在行（1-based）
    var currentLine: Int {
        let length = (string as NSString).length
        return lineNumber(atUTF16Offset: min(selectedRange().location, length))
    }

    /// 可见区域顶部行（滚动同步用）
    var topVisibleLine: Int {
        let length = (string as NSString).length
        let point = NSPoint(x: 0, y: visibleRect.minY + textContainerInset.height)
        let index = min(characterIndexForInsertion(at: point), length)
        return lineNumber(atUTF16Offset: index)
    }

    private func reportCurrentLine() {
        onLineChange?(currentLine)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        backgroundColor = .textBackgroundColor
        if let storage = textStorage, !storage.string.isEmpty {
            MarkdownHighlighter.apply(to: storage, theme: ThemeCache.shared.theme)
        }
        needsDisplay = true
    }
}

/// 主题缓存：外观切换时需要拿到当前主题重刷，避免把 theme 一路透传到视图响应链。
final class ThemeCache {
    static let shared = ThemeCache()
    var theme = EditorTheme(fontSize: 13.5, family: .sfMono)

    private var cachedKey: String = ""
    private var cached: EditorTheme?

    /// 主题带缓存。`EditorTheme.init` 每次会做 `NSFont(name:)` + 两次
    /// `NSFontManager.convert`，滚动时若每帧新建会明显吃掉帧预算。
    func theme(fontSize: CGFloat, family: EditorFontFamily) -> EditorTheme {
        let key = "\(family.rawValue)|\(fontSize)"
        if key == cachedKey, let cached { return cached }
        let made = EditorTheme(fontSize: fontSize, family: family)
        cachedKey = key
        cached = made
        return made
    }
}
