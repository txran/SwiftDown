import AppKit

/// 行号标尺（FR-04「行号可切换」）。
///
/// 设计要点（踩过的坑，见 Docs/M1-app-shell.md §六）：
/// 1. 不假定 TextKit 版本。`NSTextView(frame:)` 在现代 macOS 上默认给 TextKit 2，
///    而只要有人访问 `layoutManager` 就会被静默降级成 TextKit 1；
///    两条路径都要覆盖，按视图**当前实际**使用的引擎取行片段。
/// 2. 行号来源统一是 `MarkdownTextView` 的行索引（缓存 + 二分），标尺不维护第二份索引。
/// 3. 只枚举「可见范围内」的片段，不做全文枚举——后者每帧 O(全文)，是大文档滚动卡顿的主因。
final class LineNumberRulerView: NSRulerView {

    var theme: EditorTheme {
        didSet { needsDisplay = true }
    }

    /// 行号渲染上限：超过后不再绘制（大文档下逐行枚举收益低于成本）
    static let textLengthLimit = 2 * 1024 * 1024

    private static let minThickness: CGFloat = 46
    private static let digitPadding: CGFloat = 8

    private var metrics = TextMetrics(lineCount: 1, version: -1)

    /// 行数变化后需要重算标尺宽度
    private struct TextMetrics {
        let lineCount: Int
        let version: Int
    }

    init(scrollView: NSScrollView, textView: NSTextView, theme: EditorTheme) {
        self.theme = theme
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        self.clientView = textView
        self.ruleThickness = Self.minThickness
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    /// 文本变化时显式刷新（等长编辑也要重算宽度与编号）
    func invalidateLineIndex() {
        metrics = TextMetrics(lineCount: metrics.lineCount, version: -1)
        needsDisplay = true
    }

    /// 换文档时**主动**重算行号栏宽度，不要等下一次 `draw`。
    ///
    /// 宽度原本只在 `drawHashMarksAndLabels` 里更新，于是「标尺变宽」比
    /// 「文本区重排」晚一帧，换文档时能看到一次横向跳动。
    /// 位数变化（例：12 行 → 1200 行）时这一步尤其明显。
    func prepareForNewDocument() {
        guard let textView = clientView as? MarkdownTextView else { return }
        metrics = TextMetrics(lineCount: 0, version: -1)   // 强制重算，不信任旧版本号
        syncMetrics(textView)
        needsDisplay = true
    }

    // MARK: - 自检入口

    /// 自检用：当前可见行号（验证绘制内容非空）
    func debugVisibleLineNumbers() -> [Int] {
        guard let textView = clientView as? MarkdownTextView,
              let storage = textView.textStorage,
              storage.length <= Self.textLengthLimit else { return [] }
        return visibleEntries(textView: textView).map(\.number)
    }

    /// 自检用：当前实际使用的排版引擎（`NSTextView(frame:)` 在现代 macOS 上是 TextKit 2，
    /// 一旦有人访问 `layoutManager` 就会被静默降级为 TextKit 1）
    var debugLayoutEngineName: String {
        (clientView as? MarkdownTextView)?.textLayoutManager == nil ? "TextKit1" : "TextKit2"
    }

    // MARK: - 绘制

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = clientView as? MarkdownTextView else { return }

        // 背景
        NSColor.textBackgroundColor.setFill()
        bounds.fill()

        // 右侧分隔线
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 1, y: bounds.minY, width: 1, height: bounds.height).fill()

        guard let storage = textView.textStorage, storage.length <= Self.textLengthLimit else { return }
        syncMetrics(textView)

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: max(9, theme.baseFont.pointSize - 2),
                                                    weight: .regular),
            .foregroundColor: NSColor.tertiaryLabelColor
        ]

        for entry in visibleEntries(textView: textView) {
            let text = "\(entry.number)" as NSString
            let size = text.size(withAttributes: attributes)
            let point = NSPoint(x: ruleThickness - size.width - Self.digitPadding,
                                y: entry.y + max(0, (entry.height - size.height) / 2))
            text.draw(at: point, withAttributes: attributes)
        }
    }

    private func syncMetrics(_ textView: MarkdownTextView) {
        textView.ensureLineIndex()
        if metrics.version == textView.lineIndexVersion { return }
        metrics = TextMetrics(lineCount: textView.logicalLineCount,
                              version: textView.lineIndexVersion)
        let digits = max(2, String(metrics.lineCount).count)
        let wanted = max(Self.minThickness, CGFloat(digits) * 8 + Self.digitPadding + 10)
        if abs(ruleThickness - wanted) > 0.5 {
            ruleThickness = wanted
        }
    }

    // MARK: - 行片段（引擎无关）

    private struct Entry {
        let number: Int
        let y: CGFloat
        let height: CGFloat
    }

    private func visibleEntries(textView: MarkdownTextView) -> [Entry] {
        if let textLayoutManager = textView.textLayoutManager {
            return entriesTextKit2(textView: textView, layoutManager: textLayoutManager)
        }
        return entriesTextKit1(textView: textView)
    }

    /// 文本坐标（textView 内，y 向下）→ 标尺坐标。
    /// 标尺与 textView 不是父子关系，必须经公共祖先换算；两者都是 flipped，等价于纯平移，
    /// 但仍然走 `convert` 以免屏内多屏/缩放时算错。
    private func rulerY(_ yInTextView: CGFloat, textView: MarkdownTextView) -> CGFloat {
        convert(NSPoint(x: 0, y: yInTextView), from: textView).y
    }

    /// TextKit 1 路径（兼容分支：一旦视图被降级为 TextKit 1 才会走到）
    private func entriesTextKit1(textView: MarkdownTextView) -> [Entry] {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return [] }

        let inset = textView.textContainerInset
        let visible = textView.visibleRect

        // 只取可见范围的 glyph，避免全文布局枚举
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visible, in: container)
        var entries: [Entry] = []

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) { rect, _, _, lineGlyphRange, _ in
            let charIndex = layoutManager.characterIndexForGlyph(at: lineGlyphRange.location)
            // 自动换行产生的续行不重复标号：只有逻辑行首才画
            guard textView.isLogicalLineStart(charIndex) else { return }
            entries.append(Entry(number: textView.lineNumber(atUTF16Offset: charIndex),
                                 y: self.rulerY(rect.minY + inset.height, textView: textView),
                                 height: rect.height))
        }
        return entries
    }

    /// TextKit 2 路径（**生产环境实际使用的引擎**）
    ///
    /// 两个易错点：
    /// 1. `NSTextLineFragment.characterRange` 是「相对文本元素（段落）」的偏移，不是全文偏移。
    ///    直接拿 `.location` 当全文偏移，会让每个段落的第 1 行都算成第 1 行；
    ///    必须叠加 `fragment.rangeInElement.location` 换算出的元素起点。
    /// 2. 从文档头枚举会给整篇文档布局（大文档下每帧 O(全文)），
    ///    因此从「可见顶部上方几行」开始，越过可见底部立刻停止。
    private func entriesTextKit2(textView: MarkdownTextView,
                                 layoutManager: NSTextLayoutManager) -> [Entry] {
        let inset = textView.textContainerInset
        let visible = textView.visibleRect
        let length = (textView.string as NSString).length

        let startLine = max(1, textView.topVisibleLine - 4)
        let startOffset = min(textView.offset(ofLine: startLine), max(0, length))
        guard let start = layoutManager.location(layoutManager.documentRange.location,
                                                 offsetBy: startOffset) else { return [] }

        var entries: [Entry] = []
        layoutManager.enumerateTextLayoutFragments(from: start, options: [.ensuresLayout]) { fragment in
            // fragment 的 frame 在文本容器坐标里，容器原点已含 inset，故这里补上
            let fragmentY = fragment.layoutFragmentFrame.minY + inset.height
            if self.rulerY(fragmentY, textView: textView) > visible.maxY + 60 { return false }

            let elementStart = layoutManager.offset(from: layoutManager.documentRange.location,
                                                    to: fragment.rangeInElement.location)

            for lineFragment in fragment.textLineFragments {
                let y = self.rulerY(fragmentY + lineFragment.typographicBounds.minY, textView: textView)
                if y > visible.maxY + 60 { break }
                let charIndex = elementStart + lineFragment.characterRange.location
                guard charIndex >= 0, charIndex <= length,
                      textView.isLogicalLineStart(charIndex) else { continue }
                entries.append(Entry(number: textView.lineNumber(atUTF16Offset: charIndex),
                                     y: y,
                                     height: lineFragment.typographicBounds.height))
            }
            return true
        }
        return entries
    }
}
