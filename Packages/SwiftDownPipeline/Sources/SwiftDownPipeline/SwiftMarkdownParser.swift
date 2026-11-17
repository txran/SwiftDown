import Foundation
import Markdown

/// swift-markdown 实现（设计文档 §三 首选方案）。
/// 职责：把 swift-markdown 的 Markup 树转换为稳定的抽象 AST，屏蔽第三方类型。
public struct SwiftMarkdownParser: MarkdownParsing {

    public init() {}

    public func parse(_ source: String) throws -> MarkdownAST {
        let document = Document(parsing: source)
        let lines = source.components(separatedBy: .newlines)
        let collector = HeadingCollector()

        var blocks: [BlockNode] = []
        blocks.reserveCapacity(document.childCount)
        for child in document.children {
            if let block = convertBlock(child, lines: lines, headings: collector) {
                blocks.append(block)
            }
        }
        return MarkdownAST(blocks: blocks, headings: collector.items)
    }

    // MARK: - 块级转换

    private func convertBlock(_ node: Markup,
                              lines: [String],
                              headings: HeadingCollector) -> BlockNode? {
        let line = sourceLine(of: node)

        switch node {
        case let heading as Heading:
            let inlines = convertInlines(heading.children)
            let plain = inlines.plainText
            headings.items.append(
                HeadingNode(id: "h-\(heading.level)-\(line)",
                            level: heading.level,
                            plainText: plain,
                            sourceLine: line)
            )
            return .heading(level: heading.level, inlines: inlines, sourceLine: line)

        case let paragraph as Paragraph:
            return .paragraph(inlines: convertInlines(paragraph.children), sourceLine: line)

        case let code as CodeBlock:
            return .codeBlock(language: code.language, code: code.code, sourceLine: line)

        case let list as UnorderedList:
            return .list(ordered: false,
                         start: 1,
                         items: list.listItems.map { convertListItem($0, lines: lines, headings: headings) },
                         sourceLine: line)

        case let list as OrderedList:
            return .list(ordered: true,
                         start: Int(list.startIndex),
                         items: list.listItems.map { convertListItem($0, lines: lines, headings: headings) },
                         sourceLine: line)

        case let table as Table:
            let header: [[InlineNode]] = Array(table.head.cells.map { convertInlines($0.children) })
            let rows: [[[InlineNode]]] = Array(table.body.rows.map { row in
                Array(row.cells.map { convertInlines($0.children) })
            })
            return .table(header: header, rows: rows, sourceLine: line)

        case let quote as BlockQuote:
            var inner: [BlockNode] = []
            for child in quote.children {
                if let b = convertBlock(child, lines: lines, headings: headings) {
                    inner.append(b)
                }
            }
            return .blockQuote(blocks: inner, sourceLine: line)

        case is ThematicBreak:
            return .thematicBreak(sourceLine: line)

        case let html as HTMLBlock:
            return .htmlBlock(html: html.rawHTML, sourceLine: line)

        default:
            // FR-02 / RK-04：未知语法原样降级，不报错、不丢失
            return .fallback(source: sourceSlice(node, lines: lines), sourceLine: line)
        }
    }

    private func convertListItem(_ item: Markdown.ListItem,
                                 lines: [String],
                                 headings: HeadingCollector) -> SwiftDownPipeline.ListItem {
        let blocks: [BlockNode] = item.children.compactMap {
            convertBlock($0, lines: lines, headings: headings)
        }
        let checkbox: Bool?
        switch item.checkbox {
        case .some(.checked): checkbox = true
        case .some(.unchecked): checkbox = false
        case .none: checkbox = nil
        }
        return SwiftDownPipeline.ListItem(blocks: blocks, checkbox: checkbox)
    }

    // MARK: - 行内转换

    /// 原地追加以避免 flatMap 的逐节点临时数组分配（1MB 文档下为热点路径）
    private func convertInlines(_ children: MarkupChildren) -> [InlineNode] {
        var result: [InlineNode] = []
        for child in children {
            appendInline(child, into: &result)
        }
        return result
    }

    private func appendInline(_ node: Markup, into result: inout [InlineNode]) {
        switch node {
        case let text as Text:
            result.append(.text(text.string))
        case let code as InlineCode:
            result.append(.inlineCode(code.code))
        case let emphasis as Emphasis:
            result.append(.emphasis(convertInlines(emphasis.children)))
        case let strong as Strong:
            result.append(.strong(convertInlines(strong.children)))
        case let strike as Strikethrough:
            result.append(.strikethrough(convertInlines(strike.children)))
        case let link as Link:
            result.append(.link(destination: link.destination ?? "",
                                children: convertInlines(link.children)))
        case let image as Image:
            result.append(.image(source: image.source ?? "",
                                 alt: convertInlines(image.children).plainText))
        case is SoftBreak:
            result.append(.softBreak)
        case is LineBreak:
            result.append(.hardBreak)
        default:
            let formatted = node.format().trimmingCharacters(in: .whitespacesAndNewlines)
            if !formatted.isEmpty {
                result.append(.text(formatted))
            }
        }
    }

    // MARK: - 辅助

    private func sourceLine(of node: Markup) -> Int {
        node.range?.lowerBound.line ?? 1
    }

    /// 取原始源码片段（降级块展示用），按行范围截取
    private func sourceSlice(_ node: Markup, lines: [String]) -> String {
        guard let range = node.range, !lines.isEmpty else {
            return node.format()
        }
        let start = max(1, range.lowerBound.line)
        let end = min(lines.count, max(start, range.upperBound.line))
        guard start <= end else { return node.format() }
        return lines[(start - 1)...(end - 1)].joined(separator: "\n")
    }
}

/// 标题树收集器（避免 inout 闭包捕获）
final class HeadingCollector {
    var items: [HeadingNode] = []
}

// MARK: - 性能诊断入口（internal，仅测试使用）

extension SwiftMarkdownParser {
    /// 只执行第三方解析、不做 AST 转换，返回顶层块数。
    /// 用于分离「cmark 解析耗时」与「AST 转换耗时」。
    func rawParseOnly(_ source: String) -> Int {
        Document(parsing: source).childCount
    }
}
