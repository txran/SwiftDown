import AppKit
import Foundation

/// 一个字符在「就地编辑」里的角色，可以叠加（`**粗体链接**` 同时是 strong + link）。
struct PreviewCharStyle: OptionSet, Equatable {
    let rawValue: UInt8
    init(rawValue: UInt8) { self.rawValue = rawValue }

    /// 块级前缀：`#` / `>` / `-` / `1.` / `[ ]`。**始终淡显**——
    /// 把它藏起来会连列表的缩进一起吃掉，行首位置就会跳，反而更乱。
    static let blockPrefix = PreviewCharStyle(rawValue: 1 << 0)
    /// 行内标记：`**` `_` `~~` `` ` `` `[` `](url)`。**只在光标行显形**，其余行隐藏。
    static let markup = PreviewCharStyle(rawValue: 1 << 1)
    static let strong = PreviewCharStyle(rawValue: 1 << 2)
    static let emphasis = PreviewCharStyle(rawValue: 1 << 3)
    static let strike = PreviewCharStyle(rawValue: 1 << 4)
    static let code = PreviewCharStyle(rawValue: 1 << 5)
    static let link = PreviewCharStyle(rawValue: 1 << 6)
}

/// 一段 Markdown 源文本的「标记 / 内容」地图。
///
/// 只用来看：把标记画得透明、把内容画成粗体/斜体/行内代码/链接色。
/// **它不参与写回**——写回用的是编辑框里的原文本身，所以这张表算错最多是排版难看，
/// 不会改坏文档。这是 ADR-22 的核心约束：宁可样式不准，也不许映射错位。
///
/// 下标一律用 **UTF-16**（与 `NSAttributedString` / `NSLayoutManager` 同口径），
/// 这样点击位置、选区、链接命中可以直接比较，不用来回换算。
struct PreviewInlineMap {

    struct Link {
        let range: NSRange
        let url: String
    }

    let text: String
    /// 长度 = `text.utf16.count`，逐 UTF-16 单元
    let styles: [PreviewCharStyle]
    let links: [Link]
    let lineStarts: [Int]

    func lineIndex(at location: Int) -> Int {
        FindEngine.lineNumber(at: max(0, location), lineStarts: lineStarts) - 1
    }

    // MARK: - 构建

    static func build(_ text: String) -> PreviewInlineMap {
        let chars = Array(text)
        // Character 下标 → UTF-16 偏移
        var utf16 = [Int]()
        utf16.reserveCapacity(chars.count + 1)
        var cursor = 0
        for char in chars {
            utf16.append(cursor)
            cursor += String(char).utf16.count
        }
        utf16.append(cursor)

        var styles = [PreviewCharStyle](repeating: [], count: cursor)
        var links: [Link] = []

        var lineRanges: [Range<Int>] = []
        var start = 0
        for (index, char) in chars.enumerated() where char == "\n" {
            lineRanges.append(start..<index)
            start = index + 1
        }
        lineRanges.append(start..<chars.count)

        for line in lineRanges {
            let prefix = prefixLength(chars, line)
            mark(&styles, utf16, line.lowerBound, line.lowerBound + prefix, .blockPrefix)
            scanInline(chars, (line.lowerBound + prefix)..<line.upperBound, &styles, &links, utf16)
        }

        return PreviewInlineMap(text: text,
                                styles: styles,
                                links: links,
                                lineStarts: FindEngine.lineStarts(of: text as NSString))
    }

    // MARK: - 块级前缀

    /// 行首的块级标记长度：前导空白 + 引用号 + 标题井号 / 列表符号 / 任务框
    private static func prefixLength(_ chars: [Character], _ line: Range<Int>) -> Int {
        let start = line.lowerBound
        var i = start
        while i < line.upperBound, chars[i] == " " || chars[i] == "\t" { i += 1 }

        while i < line.upperBound, chars[i] == ">" {
            i += 1
            if i < line.upperBound, chars[i] == " " { i += 1 }
        }

        if i < line.upperBound, chars[i] == "#" {
            var j = i
            while j < line.upperBound, chars[j] == "#" { j += 1 }
            if j - i <= 6, j < line.upperBound, chars[j] == " " { return j + 1 - start }
        }

        if i < line.upperBound, "-*+".contains(chars[i]),
           i + 1 < line.upperBound, chars[i + 1] == " " {
            i += 2
        } else if i < line.upperBound, chars[i].isNumber {
            var j = i
            while j < line.upperBound, chars[j].isNumber { j += 1 }
            if j < line.upperBound, chars[j] == "." || chars[j] == ")",
               j + 1 < line.upperBound, chars[j + 1] == " " {
                i = j + 2
            }
        }

        if i + 3 < line.upperBound, chars[i] == "[",
           " xX".contains(chars[i + 1]), chars[i + 2] == "]", chars[i + 3] == " " {
            i += 4
        }
        return i - start
    }

    // MARK: - 行内

    private static func scanInline(_ chars: [Character],
                                   _ range: Range<Int>,
                                   _ styles: inout [PreviewCharStyle],
                                   _ links: inout [Link],
                                   _ utf16: [Int]) {
        markEscapes(chars, range, &styles, utf16)
        markCodeSpans(chars, range, &styles, utf16)
        markLinks(chars, range, &styles, &links, utf16)
        markEmphasis(chars, range, &styles, utf16)
    }

    /// `\*` 这类转义：反斜杠是标记，后面的字符照常显示
    private static func markEscapes(_ chars: [Character],
                                    _ range: Range<Int>,
                                    _ styles: inout [PreviewCharStyle],
                                    _ utf16: [Int]) {
        var i = range.lowerBound
        while i < range.upperBound {
            if chars[i] == "\\", i + 1 < range.upperBound, styles[i].isEmpty {
                mark(&styles, utf16, i, i + 1, .markup)
                i += 2
                continue
            }
            i += 1
        }
    }

    /// 行内代码：反引号串 + 等长闭合串，中间原样保留
    private static func markCodeSpans(_ chars: [Character],
                                      _ range: Range<Int>,
                                      _ styles: inout [PreviewCharStyle],
                                      _ utf16: [Int]) {
        var i = range.lowerBound
        while i < range.upperBound {
            guard styles[i].isEmpty, chars[i] == "`" else { i += 1; continue }
            var open = i
            while open < range.upperBound, chars[open] == "`" { open += 1 }
            let runLength = open - i

            var close = -1
            var probe = open
            while probe < range.upperBound {
                if chars[probe] == "`", styles[probe].isEmpty {
                    var end = probe
                    while end < range.upperBound, chars[end] == "`" { end += 1 }
                    if end - probe == runLength { close = probe; break }
                    probe = end
                } else {
                    probe += 1
                }
            }

            guard close > 0 else { i = open; continue }
            mark(&styles, utf16, i, open, .markup)
            mark(&styles, utf16, open, close, .code)
            mark(&styles, utf16, close, close + runLength, .markup)
            i = close + runLength
        }
    }

    /// `[label](dest)` 与 `![alt](src)`：括号与地址是标记，label 是链接内容
    private static func markLinks(_ chars: [Character],
                                  _ range: Range<Int>,
                                  _ styles: inout [PreviewCharStyle],
                                  _ links: inout [Link],
                                  _ utf16: [Int]) {
        var i = range.lowerBound
        while i < range.upperBound {
            guard styles[i].isEmpty else { i += 1; continue }

            var open = i
            var isImage = false
            if chars[i] == "!", i + 1 < range.upperBound, chars[i + 1] == "[" {
                isImage = true
                open = i + 1
            }
            guard chars[open] == "[" else { i += 1; continue }

            var depth = 0
            var close = -1
            var j = open
            while j < range.upperBound {
                if chars[j] == "[" { depth += 1 }
                if chars[j] == "]" {
                    depth -= 1
                    if depth == 0 { close = j; break }
                }
                j += 1
            }
            guard close > open, close + 1 < range.upperBound, chars[close + 1] == "(" else {
                i += 1
                continue
            }

            var parenDepth = 0
            var destinationEnd = -1
            var k = close + 1
            while k < range.upperBound {
                if chars[k] == "(" { parenDepth += 1 }
                if chars[k] == ")" {
                    parenDepth -= 1
                    if parenDepth == 0 { destinationEnd = k; break }
                }
                k += 1
            }
            guard destinationEnd > 0 else { i += 1; continue }

            if isImage {
                // 图片整段隐藏：预览里它是一张图，不是文字
                mark(&styles, utf16, i, destinationEnd + 1, .markup)
            } else {
                mark(&styles, utf16, open, open + 1, .markup)
                mark(&styles, utf16, close, destinationEnd + 1, .markup)
                mark(&styles, utf16, open + 1, close, .link)
                let destination = String(chars[(close + 2)..<destinationEnd])
                links.append(Link(range: NSRange(location: utf16[open + 1],
                                                 length: utf16[close] - utf16[open + 1]),
                                  url: destination))
            }
            i = destinationEnd + 1
        }
    }

    /// `**` / `*` / `_` / `~~`：用分隔符栈配对，支持嵌套（`**粗 *斜* 粗**`）
    private static func markEmphasis(_ chars: [Character],
                                     _ range: Range<Int>,
                                     _ styles: inout [PreviewCharStyle],
                                     _ utf16: [Int]) {
        var stack: [(char: Character, start: Int, length: Int)] = []
        var i = range.lowerBound
        while i < range.upperBound {
            let char = chars[i]
            guard char == "*" || char == "_" || char == "~", styles[i].isEmpty else {
                i += 1
                continue
            }
            var end = i
            while end < range.upperBound, chars[end] == char { end += 1 }
            let length = end - i

            let previous = i > range.lowerBound ? chars[i - 1] : nil
            let next = end < range.upperBound ? chars[end] : nil
            var canOpen = !(next?.isWhitespace ?? true)
            var canClose = !(previous?.isWhitespace ?? true)
            if char == "_" {
                // 词内下划线（snake_case）不是强调——和 CommonMark 同口径
                if let previous, previous.isLetter || previous.isNumber { canOpen = false }
                if let next, next.isLetter || next.isNumber { canClose = false }
            }
            if char == "~", length < 2 { canOpen = false; canClose = false }

            if canClose, let openerIndex = stack.lastIndex(where: { $0.char == char }) {
                let opener = stack.remove(at: openerIndex)
                mark(&styles, utf16, opener.start, opener.start + opener.length, .markup)
                mark(&styles, utf16, i, end, .markup)

                var inner = PreviewCharStyle()
                if char == "~" {
                    inner = .strike
                } else {
                    if opener.length >= 2 { inner.insert(.strong) }
                    if opener.length % 2 == 1 { inner.insert(.emphasis) }
                }
                let lower = utf16[opener.start + opener.length]
                let upper = utf16[i]
                guard lower < upper else { i = end; continue }
                for k in lower..<upper where !styles[k].contains(.code) && !styles[k].contains(.markup) {
                    styles[k].formUnion(inner)
                }
            } else if canOpen {
                stack.append((char, i, length))
            }
            i = end
        }
    }

    // MARK: - 工具

    private static func mark(_ styles: inout [PreviewCharStyle],
                             _ utf16: [Int],
                             _ from: Int,
                             _ to: Int,
                             _ style: PreviewCharStyle) {
        guard from >= 0, to <= utf16.count - 1, from < to else { return }
        let lower = utf16[from]
        let upper = utf16[to]
        guard lower < upper, upper <= styles.count else { return }
        for k in lower..<upper { styles[k].insert(style) }
    }
}

// MARK: - 画成渲染后的样子

enum PreviewLiveStyler {

    struct Appearance: Equatable {
        var fontSize: CGFloat
        var bold = false
        var secondary = false
        var mono = false
        var language: String?
        var lineSpacing: CGFloat = 4
    }

    /// 隐藏标记用的字号。不能靠 `.kern` 压宽度——负字距会把后一个字拉过来叠着。
    private static let hiddenFontSize: CGFloat = 0.1

    static func baseFont(_ appearance: Appearance) -> NSFont {
        if appearance.mono {
            return NSFont.monospacedSystemFont(ofSize: appearance.fontSize, weight: .regular)
        }
        return NSFont.systemFont(ofSize: appearance.fontSize,
                                 weight: appearance.bold ? .bold : .regular)
    }

    static func baseColor(_ appearance: Appearance) -> NSColor {
        appearance.secondary ? .secondaryLabelColor : .labelColor
    }

    static func attributed(_ map: PreviewInlineMap,
                           appearance: Appearance,
                           caretLine: Int) -> NSAttributedString {
        if appearance.mono {
            return monoAttributed(map.text, appearance: appearance)
        }

        // 整块都被标记吃光时（典型：只有一个 `![](img.png)` 的段落）不能把标记藏起来，
        // 否则点进去是个空框，用户既看不到东西也没法判断自己在改什么。
        let hideMarkup = map.styles.contains { !$0.contains(.markup) }

        let baseFont = baseFont(appearance)
        let baseColor = baseColor(appearance)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = appearance.lineSpacing

        let result = NSMutableAttributedString()
        var runStart = 0
        var runKey = key(map, at: 0, caretLine: caretLine, hideMarkup: hideMarkup)

        func flush(_ end: Int) {
            guard end > runStart else { return }
            let text = (map.text as NSString).substring(with: NSRange(location: runStart,
                                                                     length: end - runStart))
            result.append(NSAttributedString(string: text,
                                             attributes: attributes(runKey,
                                                                    appearance: appearance,
                                                                    baseFont: baseFont,
                                                                    baseColor: baseColor,
                                                                    paragraph: paragraph)))
        }

        for index in 1..<max(1, map.styles.count) {
            let next = key(map, at: index, caretLine: caretLine, hideMarkup: hideMarkup)
            if next != runKey {
                flush(index)
                runStart = index
                runKey = next
            }
        }
        flush(map.styles.count)
        return result
    }

    private static func monoAttributed(_ text: String, appearance: Appearance) -> NSAttributedString {
        let highlighted = NSMutableAttributedString(
            attributedString: CodeHighlighter.highlightedNS(text,
                                                            language: appearance.language,
                                                            size: appearance.fontSize))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 0
        if highlighted.length > 0 {
            highlighted.addAttribute(.paragraphStyle,
                                     value: paragraph,
                                     range: NSRange(location: 0, length: highlighted.length))
        }
        return highlighted
    }

    private enum RunKey: Equatable {
        case hidden
        case dimmed
        case content(PreviewCharStyle)
    }

    private static func key(_ map: PreviewInlineMap,
                            at index: Int,
                            caretLine: Int,
                            hideMarkup: Bool) -> RunKey {
        guard index < map.styles.count else { return .content([]) }
        let style = map.styles[index]
        if style.contains(.blockPrefix) { return .dimmed }
        if style.contains(.markup) {
            guard hideMarkup else { return .dimmed }
            return map.lineIndex(at: index) == caretLine ? .dimmed : .hidden
        }
        return .content(style)
    }

    private static func attributes(_ key: RunKey,
                                   appearance: Appearance,
                                   baseFont: NSFont,
                                   baseColor: NSColor,
                                   paragraph: NSParagraphStyle) -> [NSAttributedString.Key: Any] {
        switch key {
        case .hidden:
            return [.font: NSFont.systemFont(ofSize: hiddenFontSize),
                    .foregroundColor: NSColor.clear,
                    .paragraphStyle: paragraph]

        case .dimmed:
            return [.font: baseFont,
                    .foregroundColor: NSColor.tertiaryLabelColor,
                    .paragraphStyle: paragraph]

        case .content(let style):
            var attrs: [NSAttributedString.Key: Any] = [.font: baseFont,
                                                        .foregroundColor: baseColor,
                                                        .paragraphStyle: paragraph]
            if style.contains(.code) {
                attrs[.font] = NSFont.monospacedSystemFont(ofSize: max(8, appearance.fontSize - 0.5),
                                                           weight: .regular)
                attrs[.backgroundColor] = NSColor.quaternaryLabelColor
            } else if style.contains(.strong) || style.contains(.emphasis) {
                var font = baseFont
                if style.contains(.strong) {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                }
                if style.contains(.emphasis) {
                    font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
                }
                attrs[.font] = font
            }
            if style.contains(.strike) {
                attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
            }
            if style.contains(.link) {
                attrs[.foregroundColor] = NSColor.linkColor
                attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            return attrs
        }
    }
}

// MARK: - 量尺寸 / 找光标

/// 用同一套排版参数做「离线测量」：高度和点击落点都靠它，
/// 这样不需要等 `NSView` 布局完就能算，自检里也能直接断言。
enum PreviewTextMetrics {

    static func height(_ attributed: NSAttributedString, width: CGFloat) -> CGFloat {
        let (storage, manager, container) = layout(attributed, width: width)
        manager.ensureLayout(for: container)
        let used = manager.usedRect(for: container)
        withExtendedLifetime(storage) {}
        return ceil(used.height)
    }

    /// 点（左上原点）→ 字符下标（UTF-16）。落在字的右半边就放到字后面。
    static func caretIndex(_ attributed: NSAttributedString,
                           width: CGFloat,
                           at point: CGPoint) -> Int {
        guard attributed.length > 0 else { return 0 }
        // 必须绑住 storage：NSLayoutManager 对它是弱持有，解开元组就悬空了
        let (storage, manager, container) = layout(attributed, width: width)
        manager.ensureLayout(for: container)
        let probe = NSPoint(x: max(0, point.x), y: max(0, point.y))
        let glyph = manager.glyphIndex(for: probe, in: container)
        var index = manager.characterIndexForGlyph(at: glyph)
        let glyphRect = manager.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1),
                                            in: container)
        if probe.x > glyphRect.midX { index += 1 }
        withExtendedLifetime(storage) {}
        return min(max(0, index), attributed.length)
    }

    private static func layout(_ attributed: NSAttributedString, width: CGFloat)
        -> (NSTextStorage, NSLayoutManager, NSTextContainer) {
        let storage = NSTextStorage(attributedString: attributed)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: max(20, width),
                                                     height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        container.widthTracksTextView = false
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        return (storage, manager, container)
    }
}
