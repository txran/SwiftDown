import AppKit
import Foundation

/// 预览块的「源文本区间」映射：把 AST 的顶层块换算回原文里的字符区间。
///
/// 规则：块按 `sourceLine` 升序，第 i 块的结束行 = 第 i+1 块的起始行 − 1。
/// 末尾的空行要削掉——否则提交时会把块与块之间的空行一起重写，
/// 用户只改一个错别字，空行数量也会被「规范化」，diff 里凭空多出几行。
struct PreviewSourceMap {

    private let ns: NSString
    private let lineStarts: [Int]
    let lineCount: Int

    init(text: String) {
        let ns = text as NSString
        self.ns = ns
        self.lineStarts = FindEngine.lineStarts(of: ns)
        self.lineCount = max(1, self.lineStarts.count)
    }

    /// 块区间：`startLine` 起，到下一块前一行为止（再削尾空行）
    func range(startLine: Int, nextBlockLine: Int?) -> NSRange? {
        guard startLine >= 1, startLine <= lineCount else { return nil }
        let rawEnd = nextBlockLine.map { $0 - 1 } ?? lineCount
        var endLine = min(max(rawEnd, startLine), lineCount)
        while endLine > startLine, isBlank(line: endLine) { endLine -= 1 }
        let start = lineStarts[startLine - 1]
        let end = contentEnd(ofLine: endLine)
        guard end >= start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    func text(in range: NSRange) -> String {
        guard range.location >= 0, NSMaxRange(range) <= ns.length else { return "" }
        return ns.substring(with: range)
    }

    /// 「第 12 行」/「第 12–15 行」，给提示与日志用
    func lineLabel(for range: NSRange) -> String {
        guard range.location >= 0, NSMaxRange(range) <= ns.length else { return "" }
        let startLine = FindEngine.lineNumber(at: range.location, lineStarts: lineStarts)
        let lastOffset = range.length > 0 ? NSMaxRange(range) - 1 : range.location
        let clamped = min(max(0, lastOffset), max(0, ns.length - 1))
        let endLine = FindEngine.lineNumber(at: clamped, lineStarts: lineStarts)
        return startLine == endLine ? "第 \(startLine) 行" : "第 \(startLine)–\(endLine) 行"
    }

    /// 行尾（不含换行符）
    private func contentEnd(ofLine line: Int) -> Int {
        guard line >= 1, line <= lineStarts.count else { return ns.length }
        var start = 0
        var end = 0
        var contentsEnd = 0
        ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                        for: NSRange(location: lineStarts[line - 1], length: 0))
        return contentsEnd
    }

    private func isBlank(line: Int) -> Bool {
        let start = lineStarts[line - 1]
        let end = contentEnd(ofLine: line)
        guard end >= start else { return true }
        let body = ns.substring(with: NSRange(location: start, length: end - start))
        return body.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// 代码块里「围栏之间」的那段区间（相对块首）。
    ///
    /// 就地编辑代码块时不该让用户看见 ``` 围栏：编辑框里只放代码本身，
    /// 写完再塞回围栏中间。这样删掉一行或者按回车都不会把围栏挤走。
    static func codeInnerRange(in block: String) -> NSRange? {
        let ns = block as NSString
        guard ns.length > 0 else { return nil }

        var lineStart = 0
        var lineEnd = 0
        var contentsEnd = 0
        ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                        for: NSRange(location: 0, length: 0))
        let firstLine = ns.substring(with: NSRange(location: lineStart,
                                                   length: contentsEnd - lineStart))
        let fence = firstLine.trimmingCharacters(in: .whitespaces)
        guard fence.hasPrefix("```") || fence.hasPrefix("~~~") else { return nil }
        guard lineEnd > 0, lineEnd < ns.length else { return NSRange(location: 0, length: 0) }

        var lastStart = 0
        var lastEnd = 0
        var lastContentsEnd = 0
        ns.getLineStart(&lastStart, end: &lastEnd, contentsEnd: &lastContentsEnd,
                        for: NSRange(location: ns.length - 1, length: 0))
        let lastLine = ns.substring(with: NSRange(location: lastStart,
                                                  length: lastContentsEnd - lastStart))
        let closing = lastLine.trimmingCharacters(in: .whitespaces)

        var end = ns.length
        if closing.hasPrefix("```") || closing.hasPrefix("~~~") {
            end = max(lineEnd, lastStart - 1)   // 停在闭合围栏那一行前面的换行处
        }
        guard end > lineEnd else { return NSRange(location: lineEnd, length: 0) }
        return NSRange(location: lineEnd, length: end - lineEnd)
    }
}
