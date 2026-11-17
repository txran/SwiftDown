import AppKit
import SwiftUI

/// 编辑器配色与字体（跟随系统外观。颜色全部取自语义色，切换深浅色后重刷即可生效）
struct EditorTheme {
    let baseFont: NSFont
    let boldFont: NSFont
    let italicFont: NSFont
    let codeFont: NSFont
    let textColor: NSColor
    let headingColor: NSColor
    let markerColor: NSColor
    let inlineCodeColor: NSColor
    let secondaryColor: NSColor
    let linkColor: NSColor
    let backgroundColor: NSColor
    let gutterColor: NSColor

    init(fontSize: CGFloat, family: EditorFontFamily) {
        let size = max(9, fontSize)
        let font = NSFont(name: family.postScriptName, size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        self.baseFont = font
        self.boldFont = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
        self.italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        self.codeFont = font
        self.textColor = .textColor
        self.headingColor = .systemBlue
        self.markerColor = .systemPurple
        self.inlineCodeColor = .systemPink
        self.secondaryColor = .secondaryLabelColor
        self.linkColor = .linkColor
        self.backgroundColor = .textBackgroundColor
        self.gutterColor = .secondaryLabelColor
    }

    var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: baseFont, .foregroundColor: textColor]
    }

    var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = 2
        style.paragraphSpacing = 2
        return style
    }
}

/// Markdown 语法高亮。
///
/// 实现取舍：行级扫描 + 行内正则，而非 tree-sitter。
/// 理由——M1 的目标是「语法可见、不误伤字节」；行级扫描是无状态纯函数，
/// 对 300KB 以内文档单次 <10ms，且不会因半成品语法（用户正敲 ```）报错。
/// tree-sitter 留到 M2 做代码块内嵌高亮时再评估（设计文档 §6.4）。
enum MarkdownHighlighter {

    static func apply(to storage: NSTextStorage, theme: EditorTheme, limitTo limit: NSRange? = nil) {
        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)
        guard full.length > 0 else { return }

        let target: NSRange
        if let limit {
            // 向前扩到行首，并回落若干行以便正确判断围栏状态
            let lineRange = text.lineRange(for: NSRange(location: min(limit.location, full.length), length: 0))
            target = NSRange(location: lineRange.location,
                             length: min(full.length - lineRange.location, limit.length + lineRange.length + 4096))
        } else {
            target = full
        }

        storage.beginEditing()
        storage.setAttributes(theme.baseAttributes, range: target)
        let style = theme.paragraphStyle
        storage.addAttribute(.paragraphStyle, value: style, range: target)

        var inFence = false
        var fenceMarker = ""
        if target.location > 0 {
            inFence = fenceStateBefore(text: text, offset: target.location, marker: &fenceMarker)
        }

        var cursor = target.location
        let end = target.location + target.length
        while cursor < end {
            let lineRange = text.lineRange(for: NSRange(location: cursor, length: 0))
            let lineEnd = min(NSMaxRange(lineRange), end)
            let line = text.substring(with: NSRange(location: lineRange.location,
                                                   length: lineEnd - lineRange.location))
            highlightLine(line: line, lineLocation: lineRange.location, storage: storage,
                          theme: theme, inFence: &inFence, fenceMarker: &fenceMarker)
            cursor = lineEnd
            if lineEnd <= lineRange.location { break }
        }

        storage.endEditing()
    }

    private static func fenceStateBefore(text: NSString, offset: Int, marker: inout String) -> Bool {
        var inFence = false
        var cursor = 0
        while cursor < offset {
            let lineRange = text.lineRange(for: NSRange(location: cursor, length: 0))
            let line = text.substring(with: lineRange)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                let fence = String(trimmed.prefix(3))
                if inFence && fence == marker {
                    inFence = false
                    marker = ""
                } else if !inFence {
                    inFence = true
                    marker = fence
                }
            }
            let next = NSMaxRange(lineRange)
            if next <= cursor { break }
            cursor = next
        }
        return inFence
    }

    private static func highlightLine(line: String,
                                      lineLocation: Int,
                                      storage: NSTextStorage,
                                      theme: EditorTheme,
                                      inFence: inout Bool,
                                      fenceMarker: inout String) {
        let ns = line as NSString
        let length = ns.length
        guard length > 0 else { return }
        let full = NSRange(location: lineLocation, length: length)
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // 围栏行
        if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
            let fence = String(trimmed.prefix(3))
            if inFence && fence == fenceMarker {
                inFence = false
                fenceMarker = ""
            } else if !inFence {
                inFence = true
                fenceMarker = fence
            }
            storage.addAttributes([.foregroundColor: theme.markerColor, .font: theme.boldFont], range: full)
            return
        }

        if inFence {
            storage.addAttributes([.foregroundColor: theme.secondaryColor], range: full)
            return
        }

        // 标题
        if let match = headingMatch(trimmed) {
            var leadingSpaces = 0
            while leadingSpaces < length, ns.character(at: leadingSpaces) == 0x20 { leadingSpaces += 1 }
            let hashes = match.hashes
            if length >= leadingSpaces + hashes {
                let hashRange = NSRange(location: lineLocation + leadingSpaces, length: hashes)
                storage.addAttributes([.foregroundColor: theme.markerColor, .font: theme.boldFont], range: hashRange)
                let restLocation = lineLocation + leadingSpaces + hashes
                let restRange = NSRange(location: restLocation, length: lineLocation + length - restLocation)
                if restRange.length > 0 {
                    storage.addAttributes([.foregroundColor: theme.headingColor, .font: theme.boldFont],
                                          range: restRange)
                }
            }
            applyInlines(text: ns, base: lineLocation, storage: storage, theme: theme, skipMarkers: false)
            return
        }

        // 引用
        if trimmed.hasPrefix(">") {
            storage.addAttribute(.foregroundColor, value: theme.secondaryColor, range: full)
        }

        // 列表 / 任务标记
        if let markerRange = listMarkerRange(in: ns) {
            storage.addAttributes([.foregroundColor: theme.markerColor], range: markerRange)
        }

        // 水平线
        if isThematicBreak(trimmed) {
            storage.addAttribute(.foregroundColor, value: theme.markerColor, range: full)
            return
        }

        applyInlines(text: ns, base: lineLocation, storage: storage, theme: theme, skipMarkers: true)
    }

    private struct HeadingMatch { let hashes: Int }

    private static func headingMatch(_ trimmed: String) -> HeadingMatch? {
        var count = 0
        for ch in trimmed {
            if ch == "#" { count += 1 } else { break }
        }
        guard count >= 1, count <= 6, count < trimmed.count else { return nil }
        let after = trimmed[trimmed.index(trimmed.startIndex, offsetBy: count)]
        guard after == " " || after == "\t" else { return nil }
        return HeadingMatch(hashes: count)
    }

    private static func isThematicBreak(_ trimmed: String) -> Bool {
        guard trimmed.count >= 3 else { return false }
        let chars = Set(trimmed)
        return (chars == ["-"] || chars == ["*"] || chars == ["_"]) && !trimmed.contains(" ")
    }

    private static func listMarkerRange(in line: NSString) -> NSRange? {
        var i = 0
        while i < line.length, line.character(at: i) == 0x20 || line.character(at: i) == 0x09 { i += 1 }
        guard i < line.length else { return nil }
        let ch = line.character(at: i)
        if ch == 0x2D || ch == 0x2A || ch == 0x2B {  // - * +
            if i + 1 < line.length, line.character(at: i + 1) == 0x20 {
                return NSRange(location: i, length: 1)
            }
            return nil
        }
        var j = i
        while j < line.length, Character(UnicodeScalar(line.character(at: j)) ?? " ").isNumber { j += 1 }
        if j > i, j < line.length, line.character(at: j) == 0x2E || line.character(at: j) == 0x29 {
            return NSRange(location: i, length: j - i + 1)
        }
        return nil
    }

    /// 行内标记：**粗** *斜* ~~删~~ `码` [链](url)
    private static func applyInlines(text: NSString,
                                     base: Int,
                                     storage: NSTextStorage,
                                     theme: EditorTheme,
                                     skipMarkers: Bool) {
        guard text.length > 0 else { return }
        let range = NSRange(location: 0, length: text.length)

        for match in boldRegex.matches(in: text as String, options: [], range: range) {
            let target = NSRange(location: base + match.range.location, length: match.range.length)
            storage.addAttribute(.font, value: theme.boldFont, range: target)
            if !skipMarkers, match.range.length >= 4 {
                colorMarker(NSRange(location: target.location, length: 2), storage, theme)
                colorMarker(NSRange(location: NSMaxRange(target) - 2, length: 2), storage, theme)
            }
        }

        for match in italicRegex.matches(in: text as String, options: [], range: range) {
            let target = NSRange(location: base + match.range.location, length: match.range.length)
            storage.addAttribute(.font, value: theme.italicFont, range: target)
        }

        for match in codeRegex.matches(in: text as String, options: [], range: range) {
            let target = NSRange(location: base + match.range.location, length: match.range.length)
            storage.addAttribute(.foregroundColor, value: theme.inlineCodeColor, range: target)
        }

        for match in linkRegex.matches(in: text as String, options: [], range: range) {
            let target = NSRange(location: base + match.range.location, length: match.range.length)
            storage.addAttribute(.foregroundColor, value: theme.linkColor, range: target)
        }

        for match in strikeRegex.matches(in: text as String, options: [], range: range) {
            let target = NSRange(location: base + match.range.location, length: match.range.length)
            storage.addAttribute(.strikethroughStyle,
                                 value: NSUnderlineStyle.single.rawValue,
                                 range: target)
        }
    }

    private static func colorMarker(_ range: NSRange, _ storage: NSTextStorage, _ theme: EditorTheme) {
        guard range.location >= 0, NSMaxRange(range) <= storage.length else { return }
        storage.addAttribute(.foregroundColor, value: theme.markerColor, range: range)
    }

    private static let boldRegex = try! NSRegularExpression(pattern: "\\*\\*[^*\\n]+\\*\\*")
    private static let italicRegex = try! NSRegularExpression(pattern: "(?<!\\*)\\*[^*\\n]+\\*(?!\\*)")
    private static let codeRegex = try! NSRegularExpression(pattern: "`[^`\\n]+`")
    private static let linkRegex = try! NSRegularExpression(pattern: "\\[[^\\]\\n]*\\]\\([^)\\n]*\\)")
    private static let strikeRegex = try! NSRegularExpression(pattern: "~~[^~\\n]+~~")
}
