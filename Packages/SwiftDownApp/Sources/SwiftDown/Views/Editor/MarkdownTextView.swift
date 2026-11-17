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
        usesFindBar = true
        isIncrementalSearchingEnabled = true
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
        guard !isApplyingProgrammaticChange else { return }
        onTextChange?(string)
        reportCurrentLine()
    }

    /// 整体替换（重载 / 冲突采用磁盘版 / 会话恢复）
    func replaceEntireText(with newText: String, theme: EditorTheme) {
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
