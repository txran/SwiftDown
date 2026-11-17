import Foundation
import Testing
@testable import SwiftDownEditorKit

// MARK: - TextBuffer 正确性（与 String 等价性 fuzz）

@Suite("TextBuffer")
struct TextBufferTests {

    /// 用真实 String 作为参考实现，验证缓冲区语义完全一致
    func referenceReplace(_ text: inout String, range: Range<Int>, with newText: String) {
        let ns = NSMutableString(string: text)
        let n = ns.length
        let lower = max(0, min(range.lowerBound, n))
        let upper = max(lower, min(range.upperBound, n))
        ns.replaceCharacters(in: NSRange(location: lower, length: upper - lower), with: newText)
        text = ns as String
    }

    @Test("初始化与基础查询")
    func basics() {
        let b = TextBuffer("line1\nline2\nline3")
        #expect(b.string == "line1\nline2\nline3")
        #expect(b.lineCount == 3)
        #expect(b.line(at: 1) == "line2")
        #expect(b.line(at: 5) == nil)
        #expect(b.utf16Count == 17)
        #expect(b.lineStartOffset(at: 2) == 12)
    }

    @Test("空文档")
    func empty() {
        let b = TextBuffer("")
        #expect(b.string == "")
        #expect(b.lineCount == 1)
        #expect(b.utf16Count == 0)
        #expect(b.line(at: 0) == "")
    }

    @Test("单行内插入与替换")
    func singleLineEdits() {
        var b = TextBuffer("hello world")
        b.replace(range: 5..<5, with: ",")
        #expect(b.string == "hello, world")
        b.replace(range: 0..<5, with: "HI")
        #expect(b.string == "HI, world")
        b.delete(range: 2..<4)
        #expect(b.string == "HIworld")
    }

    @Test("跨行替换合并为单行")
    func crossLineMerge() {
        var b = TextBuffer("aaa\nbbb\nccc")
        b.replace(range: 1..<9, with: "X")   // 删除 a|aa\nbbb\n|cc 中的中间部分
        #expect(b.string == "aXcc")
    }

    @Test("插入含换行的文本")
    func insertMultiline() {
        var b = TextBuffer("ab")
        b.insert("\ncd\nef", at: 1)
        #expect(b.string == "a\ncd\nef b".replacingOccurrences(of: " b", with: "b"))
        #expect(b.lineCount == 3)
    }

    @Test("UTF-16 偏移：中文与 emoji")
    func utf16Offsets() {
        var b = TextBuffer("中文🙂test")
        // "中文" = 2 UTF-16 unit（各 1），"🙂" = 2 UTF-16 unit（surrogate pair），"test" = 4
        #expect(b.utf16Count == 8)
        b.insert("!", at: 2)
        #expect(b.string == "中文!🙂test")
        let idx = b.string as NSString
        #expect(idx.substring(with: NSRange(location: 3, length: 2)) == "🙂")
    }

    @Test("行号定位（同步滚动依据）")
    func lineIndexLookup() {
        let b = TextBuffer("aaa\nbb\ncccc")
        #expect(b.lineIndex(at: 0) == 0)
        #expect(b.lineIndex(at: 3) == 0)      // 行尾
        #expect(b.lineIndex(at: 4) == 1)      // 第二行开头
        #expect(b.lineIndex(at: 9) == 2)
        #expect(b.lineIndex(at: 13) == 2)     // 末尾
    }

    @Test("跨块编辑（>512 行触发分块）")
    func crossChunkEdits() {
        let lines = (0..<2000).map { "第\($0)行内容" }
        var b = TextBuffer(lines.joined(separator: "\n"))
        #expect(b.lineCount == 2000)
        #expect(b.line(at: 1500) == "第1500行内容")

        // 在块边界附近替换
        let offset = b.lineStartOffset(at: 512)!
        b.insert("插入-", at: offset)
        #expect(b.line(at: 512) == "插入-第512行内容")
        #expect(b.lineCount == 2000)

        // 删除一行（含换行）
        let delStart = b.lineStartOffset(at: 1000)!
        let delEnd = b.lineStartOffset(at: 1001)!
        b.delete(range: delStart..<delEnd)
        #expect(b.lineCount == 1999)
        #expect(b.line(at: 1000) == "第1001行内容")
    }

    @Test("随机编辑 fuzz：与 String 参考实现完全一致")
    func fuzzEquivalence() {
        var rng = SystemRandomNumberGenerator()
        let alphabet = Array("abc中🙂\n x")
        for round in 0..<60 {
            var buffer = TextBuffer("start")
            var reference = "start"
            for _ in 0..<40 {
                let n = reference.utf16.count
                let lower = Int.random(in: 0...max(0, n), using: &rng)
                let upper = Int.random(in: lower...max(lower, n), using: &rng)
                let len = Int.random(in: 0...6, using: &rng)
                let insert = String((0..<len).map { _ in alphabet.randomElement(using: &rng)! })
                // 避免在 emoji surrogate 中间切断（NSString 语义下不允许半对）
                let safeLower = safeBoundary(reference, lower)
                let safeUpper = max(safeLower, safeBoundary(reference, upper))
                buffer.replace(range: safeLower..<safeUpper, with: insert)
                referenceReplace(&reference, range: safeLower..<safeUpper, with: insert)
                #expect(buffer.string == reference, "round \(round) 不一致")
                #expect(buffer.utf16Count == reference.utf16.count, "round \(round) 长度不一致")
                #expect(buffer.lineCount == reference.components(separatedBy: "\n").count)
            }
        }
    }

    /// 把偏移对齐到不拆分 surrogate pair 的位置
    func safeBoundary(_ s: String, _ offset: Int) -> Int {
        let ns = s as NSString
        let clamped = max(0, min(offset, ns.length))
        guard clamped > 0, clamped < ns.length else { return clamped }
        let unit = ns.character(at: clamped - 1)
        let isHighSurrogate = unit >= 0xD800 && unit <= 0xDBFF
        return isHighSurrogate ? clamped - 1 : clamped
    }

    @Test("10MB 文档性能基线（NFR-02）")
    func largeDocumentPerformance() {
        let lines = (0..<200_000).map { "第\($0)行：这是用于性能测试的正文内容，包含一些中文字符与英文 text。" }
        let doc = lines.joined(separator: "\n")
        #expect(doc.utf8.count > 10 * 1024 * 1024)

        let t0 = Date()
        var b = TextBuffer(doc)
        let buildMS = Date().timeIntervalSince(t0) * 1000

        // 中间插入（典型按键）
        let mid = b.utf16Count / 2
        let t1 = Date()
        for i in 0..<100 {
            b.insert("x", at: mid + i)
        }
        let insertMS = Date().timeIntervalSince(t1) * 1000

        // 定位
        let t2 = Date()
        for _ in 0..<1000 {
            _ = b.lineIndex(at: b.utf16Count - 1)
        }
        let locateMS = Date().timeIntervalSince(t2) * 1000

        print("[性能] 10MB 构建 \(String(format: "%.1f", buildMS))ms / 100次插入 \(String(format: "%.1f", insertMS))ms / 1000次定位 \(String(format: "%.1f", locateMS))ms")

        #expect(b.utf16Count > mid)
        #expect(insertMS < 500, "100 次插入超过 500ms")
        #expect(locateMS < 1000, "1000 次行定位超过 1s")
    }
}

// MARK: - 撤销栈

@Suite("EditorBuffer 撤销重做")
struct UndoStackTests {

    @Test("撤销恢复原文，重做恢复编辑")
    func undoRedo() {
        let buf = EditorBuffer(text: "abc")
        buf.replace(range: 3..<3, with: "def")
        #expect(buf.string == "abcdef")
        #expect(buf.canUndo)

        buf.undo()
        #expect(buf.string == "abc")
        #expect(buf.canRedo)

        buf.redo()
        #expect(buf.string == "abcdef")
    }

    @Test("多步撤销至会话开始（FR-04 无上限）")
    func multiStepUndo() {
        let buf = EditorBuffer(text: "")
        for (i, s) in ["a", "b", "c", "d", "e"].enumerated() {
            buf.replace(range: i..<i, with: s)
        }
        #expect(buf.string == "abcde")
        for _ in 0..<5 { buf.undo() }
        #expect(buf.string == "")
        #expect(!buf.canUndo)
    }

    @Test("撤销后新编辑清空重做栈")
    func newEditClearsRedo() {
        let buf = EditorBuffer(text: "abc")
        buf.replace(range: 3..<3, with: "X")
        buf.undo()
        #expect(buf.canRedo)
        buf.replace(range: 3..<3, with: "Y")
        #expect(!buf.canRedo)
        #expect(buf.string == "abcY")
    }

    @Test("软上限触发合并，撤销仍能回到起点")
    func softLimitMerges() {
        let buf = EditorBuffer(text: "", undoLimit: 10)
        // 连续在末尾追加，形成可合并的相邻差量
        for i in 0..<30 {
            let n = buf.string.utf16.count
            buf.replace(range: n..<n, with: String(i % 10))
        }
        let expected = (0..<30).map { String($0 % 10) }.joined()
        #expect(buf.string == expected)
        while buf.canUndo { buf.undo() }
        #expect(buf.string == "", "合并后仍可撤销至空文档")
    }

    @Test("reload 清空撤销栈")
    func reloadClearsUndo() {
        let buf = EditorBuffer(text: "old")
        buf.replace(range: 3..<3, with: "!")
        buf.reload(with: "disk version")
        #expect(buf.string == "disk version")
        #expect(!buf.canUndo)
    }
}

// MARK: - 语法辅助（FR-04）

@Suite("MarkdownSyntaxHelper")
struct SyntaxHelperTests {

    @Test("加粗：包裹选区")
    func boldWrap() {
        let r = MarkdownSyntaxHelper.toggleBold(text: "hello world", selection: 6..<11)
        #expect(MarkdownSyntaxHelper.apply("hello world", r) == "hello **world**")
        #expect(r.newSelection == 6..<15)
    }

    @Test("加粗：已有标记时移除")
    func boldUnwrap() {
        let text = "hello **world**"
        let r = MarkdownSyntaxHelper.toggleBold(text: text, selection: 8..<13)
        #expect(MarkdownSyntaxHelper.apply(text, r) == "hello world")
    }

    @Test("加粗：选区外紧邻标记也能移除")
    func boldUnwrapOuter() {
        let text = "**world**"
        let r = MarkdownSyntaxHelper.toggleBold(text: text, selection: 2..<7)
        #expect(MarkdownSyntaxHelper.apply(text, r) == "world")
    }

    @Test("斜体：空选区插入成对标记并把光标放中间")
    func italicEmptySelection() {
        let r = MarkdownSyntaxHelper.toggleItalic(text: "ab", selection: 1..<1)
        #expect(MarkdownSyntaxHelper.apply("ab", r) == "a**b")
        #expect(r.newSelection == 2..<2)
    }

    @Test("列表回车续行：无序列表")
    func bulletContinuation() {
        #expect(MarkdownSyntaxHelper.listContinuation(forLine: "- 项目") == "- ")
        #expect(MarkdownSyntaxHelper.listContinuation(forLine: "  - 缩进项目") == "  - ")
        #expect(MarkdownSyntaxHelper.listContinuation(forLine: "* star") == "* ")
        #expect(MarkdownSyntaxHelper.listContinuation(forLine: "+ plus") == "+ ")
    }

    @Test("列表回车续行：有序列表序号递增")
    func orderedContinuation() {
        #expect(MarkdownSyntaxHelper.listContinuation(forLine: "1. 第一") == "2. ")
        #expect(MarkdownSyntaxHelper.listContinuation(forLine: "9) 第九") == "10) ")
        #expect(MarkdownSyntaxHelper.listContinuation(forLine: "  3. 缩进") == "  4. ")
    }

    @Test("列表回车续行：任务列表保持勾选格式")
    func taskContinuation() {
        #expect(MarkdownSyntaxHelper.listContinuation(forLine: "- [ ] 待办") == "- [ ] ")
        #expect(MarkdownSyntaxHelper.listContinuation(forLine: "- [x] 完成") == "- [ ] ")
    }

    @Test("空列表项回车结束列表")
    func emptyItemEndsList() {
        #expect(MarkdownSyntaxHelper.listContinuation(forLine: "- ") == nil)
        #expect(MarkdownSyntaxHelper.listContinuation(forLine: "1. ") == nil)
        #expect(MarkdownSyntaxHelper.listContinuation(forLine: "- [ ] ") == nil)
    }

    @Test("引用行续行")
    func quoteContinuation() {
        #expect(MarkdownSyntaxHelper.listContinuation(forLine: "> 引用内容") == "> ")
        #expect(MarkdownSyntaxHelper.listContinuation(forLine: "> - 引用内列表") == "> - ")
        #expect(MarkdownSyntaxHelper.listContinuation(forLine: "> ") == nil)
    }

    @Test("普通段落不续行")
    func plainParagraph() {
        #expect(MarkdownSyntaxHelper.listContinuation(forLine: "普通段落文本") == nil)
        #expect(MarkdownSyntaxHelper.listContinuation(forLine: "") == nil)
        #expect(MarkdownSyntaxHelper.listContinuation(forLine: "# 标题") == nil)
    }
}
