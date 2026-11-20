import AppKit
import SwiftDownPipeline
import SwiftUI

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

    /// 「第 12 行」/「第 12–15 行」，给编辑框标题用
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
}

/// 预览里的「轻量编辑」：就地改这一块的 Markdown 源码，⌘↩ 提交，Esc 取消。
///
/// 刻意**不做**所见即所得：内联节点（粗体 / 链接 / 行内代码）到源区间的双向映射
/// 要改解析器，一旦映射错位就会把格式写坏；而「编辑源码、整块替换」不会产生任何
/// 语义上的魔法——用户在框里看到什么，原文里就正好是那一段。
struct BlockSourceEditor: View {

    let label: String
    let fontSize: CGFloat
    @Binding var draft: String
    let onCommit: () -> Void
    let onCancel: () -> Void

    @FocusState private var focused: Bool

    private var editorHeight: CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let count = min(max(draft.components(separatedBy: "\n").count, 2), 16)
        return CGFloat(count) * lineHeight + 16
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "pencil.line")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.accentColor)
                Text("编辑 \(label) 的 Markdown 源码")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                Button("取消", action: onCancel)
                    .controlSize(.small)
                Button("完成", action: onCommit)
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: .command)
            }

            TextEditor(text: $draft)
                .font(.system(size: fontSize, design: .monospaced))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(height: editorHeight)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color(nsColor: .separatorColor), lineWidth: 0.6)
                )
                .focused($focused)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.06)))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor.opacity(0.35), lineWidth: 0.8)
        )
        // Esc 取消。放在容器上而不是输入框上：TextEditor 聚焦时 Esc 会沿响应链冒泡上来。
        .onExitCommand(perform: onCancel)
        .onAppear { focused = true }
    }
}
