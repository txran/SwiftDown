import Foundation
import Testing
@testable import SwiftDownPipeline

@Suite("MarkdownPipeline 解析")
struct SwiftMarkdownParserTests {

    let parser = SwiftMarkdownParser()

    static let fixture = """
    # 标题一

    这是**粗体**和*斜体*与~~删除~~和`code`，[链接](https://example.com)，![图](img/a.png)

    ## 标题二

    ```python
    print("hi")
    ```

    - 项目一
    - 项目二

    1. 第一
    2. 第二

    - [ ] 未完成
    - [x] 已完成

    | 列A | 列B |
    |-----|-----|
    | 1   | 2   |

    > 引用内容

    ---
    """

    /// 源码中指定文本所在的行号（1-based），用于核对 AST 的 sourceLine
    func line(of needle: String, in source: String) -> Int {
        let lines = source.components(separatedBy: "\n")
        for (i, l) in lines.enumerated() where l.contains(needle) {
            return i + 1
        }
        return -1
    }

    // FR-02：GFM 核心语法全覆盖
    @Test("GFM 语法矩阵：块类型识别")
    func gfm_block_coverage() throws {
        let ast = try parser.parse(Self.fixture)
        let kinds = ast.blocks.map { block -> String in
            switch block {
            case .heading: return "heading"
            case .paragraph: return "paragraph"
            case .codeBlock: return "code"
            case .list: return "list"
            case .table: return "table"
            case .blockQuote: return "quote"
            case .thematicBreak: return "hr"
            case .htmlBlock: return "html"
            case .fallback: return "fallback"
            }
        }
        #expect(kinds.contains("heading"))
        #expect(kinds.filter { $0 == "paragraph" }.count >= 1)
        #expect(kinds.contains("code"))
        #expect(kinds.filter { $0 == "list" }.count == 3, "无序/有序/任务 三个列表")
        #expect(kinds.contains("table"))
        #expect(kinds.contains("quote"))
        #expect(kinds.contains("hr"))
        #expect(!kinds.contains("fallback"), "标准 GFM 不应触发降级")
    }

    @Test("代码块：语言标识与内容")
    func code_block_language() throws {
        let ast = try parser.parse(Self.fixture)
        let codeBlocks = ast.blocks.compactMap { block -> (String?, String)? in
            if case .codeBlock(let lang, let code, _) = block { return (lang, code) }
            return nil
        }
        #expect(codeBlocks.count == 1)
        #expect(codeBlocks.first?.0 == "python")
        #expect(codeBlocks.first?.1.contains("print(\"hi\")") == true)
    }

    @Test("任务列表：勾选态与普通列表区分")
    func task_list_checkbox() throws {
        let ast = try parser.parse(Self.fixture)
        var taskItems: [Bool?] = []
        for block in ast.blocks {
            if case .list(_, _, let items, _) = block {
                let boxes = items.map(\.checkbox)
                if boxes.contains(where: { $0 != nil }) {
                    taskItems = boxes
                }
            }
        }
        #expect(taskItems == [false, true], "未完成/已完成 勾选态与语义一致（FR-02 验收）")
    }

    @Test("有序列表：起始序号")
    func ordered_list_start() throws {
        let ast = try parser.parse("3. 三\n4. 四\n")
        guard case .list(let ordered, let start, let items, _) = ast.blocks.first else {
            Issue.record("应为列表块")
            return
        }
        #expect(ordered)
        #expect(start == 3)
        #expect(items.count == 2)
    }

    @Test("GFM 表格：表头与数据行")
    func gfm_table() throws {
        let ast = try parser.parse(Self.fixture)
        guard let tableBlock = ast.blocks.first(where: {
            if case .table = $0 { return true }
            return false
        }), case .table(let header, let rows, _) = tableBlock else {
            Issue.record("未解析出表格")
            return
        }
        #expect(header.count == 2, "两列")
        #expect(header[0].plainText == "列A")
        #expect(rows.count == 1)
        #expect(rows[0][1].plainText == "2")
    }

    @Test("行内元素：粗体/斜体/删除线/代码/链接/图片")
    func inline_coverage() throws {
        let ast = try parser.parse(Self.fixture)
        guard let para = ast.blocks.first(where: {
            if case .paragraph = $0 { return true }
            return false
        }), case .paragraph(let inlines, _) = para else {
            Issue.record("未解析出段落")
            return
        }
        let joined = inlines.plainText
        #expect(joined.contains("粗体"))
        #expect(joined.contains("code"))

        var hasStrong = false, hasEmphasis = false, hasStrike = false
        var hasInlineCode = false, hasLink = false, hasImage = false
        for inline in inlines {
            switch inline {
            case .strong: hasStrong = true
            case .emphasis: hasEmphasis = true
            case .strikethrough: hasStrike = true
            case .inlineCode: hasInlineCode = true
            case .link(let dest, _): hasLink = dest == "https://example.com"
            case .image(let src, let alt): hasImage = (src == "img/a.png") && (alt == "图")
            default: break
            }
        }
        #expect(hasStrong && hasEmphasis && hasStrike)
        #expect(hasInlineCode && hasLink && hasImage, "相对路径图片源必须原样保留（供渲染层按文件目录解析）")
    }

    @Test("标题树：层级、纯文本、行号（同步滚动与大纲依据）")
    func heading_tree() throws {
        let ast = try parser.parse(Self.fixture)
        #expect(ast.headings.count == 2)
        #expect(ast.headings[0].level == 1)
        #expect(ast.headings[0].plainText == "标题一")
        #expect(ast.headings[1].level == 2)
        #expect(ast.headings[1].plainText == "标题二")

        let expectedLine = line(of: "## 标题二", in: Self.fixture)
        #expect(ast.headings[1].sourceLine == expectedLine, "行号必须精确（FR-03 双向滚动定位）")
    }

    @Test("块级节点 sourceLine 与源码行一致")
    func block_line_numbers() throws {
        let ast = try parser.parse(Self.fixture)
        guard let codeBlock = ast.blocks.first(where: {
            if case .codeBlock = $0 { return true }
            return false
        }) else {
            Issue.record("无代码块")
            return
        }
        let expected = line(of: "```python", in: Self.fixture)
        #expect(codeBlock.sourceLine == expected)
    }

    @Test("空文档与纯空白文档不崩溃")
    func empty_documents() throws {
        let empty = try parser.parse("")
        #expect(empty.blocks.isEmpty)
        #expect(empty.headings.isEmpty)

        let whitespace = try parser.parse("\n\n   \n")
        #expect(whitespace.headings.isEmpty)
    }

    @Test("HTML 块保留原文（不执行、不丢弃）")
    func html_block_kept() throws {
        let ast = try parser.parse("<div class=\"x\">\nhello\n</div>\n")
        guard case .htmlBlock(let html, _) = ast.blocks.first else {
            Issue.record("应为 htmlBlock")
            return
        }
        #expect(html.contains("<div"))
    }

    @Test("嵌套引用：内部块结构保留")
    func nested_blockquote() throws {
        let md = "> # 引用内标题\n> 正文\n"
        let ast = try parser.parse(md)
        guard case .blockQuote(let inner, _) = ast.blocks.first else {
            Issue.record("应为引用块")
            return
        }
        #expect(inner.count >= 1)
        if case .heading(let level, _, _) = inner.first {
            #expect(level == 1)
        } else {
            Issue.record("引用内标题丢失")
        }
    }

    // NFR-01：1MB 文档解析预算 ≤100ms（设计文档 §6.3）
    @Test("1MB 文档解析耗时基线（预算 ≤100ms）")
    func parse_performance_1MB() throws {
        let block = "# 标题\n\n这是段落文字，含**粗体**与`代码`。[链接](https://a.b)\n\n```swift\nlet a = 1\n```\n\n- 列表项\n- 列表项\n\n"
        var source = ""
        while source.utf8.count < 1024 * 1024 {
            source += block
        }
        let start = Date()
        let ast = try parser.parse(source)
        let elapsed = Date().timeIntervalSince(start) * 1000
        #expect(!ast.blocks.isEmpty)
        #expect(!ast.headings.isEmpty)
        print("1MB 解析耗时: \(String(format: "%.1f", elapsed))ms（预算 100ms）")
    }
}
