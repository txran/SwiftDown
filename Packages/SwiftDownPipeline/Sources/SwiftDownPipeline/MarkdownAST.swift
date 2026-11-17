import Foundation

/// 抽象 AST：不暴露任何第三方解析库类型，实现可替换（swift-markdown ↔ Ink）
public struct MarkdownAST: Sendable {
    public let blocks: [BlockNode]
    public let headings: [HeadingNode]

    public init(blocks: [BlockNode], headings: [HeadingNode]) {
        self.blocks = blocks
        self.headings = headings
    }

    public static let empty = MarkdownAST(blocks: [], headings: [])
}

/// 标题节点：大纲视图（FR-09）与分屏同步滚动（FR-03）共用的锚点数据
public struct HeadingNode: Equatable, Identifiable, Sendable {
    /// 稳定锚点 id（"h-<level>-<line>"，同一文档内唯一）
    public let id: String
    public let level: Int
    public let plainText: String
    /// 源码行号（1-based），用于编辑区 ↔ 预览区双向滚动定位
    public let sourceLine: Int

    public init(id: String, level: Int, plainText: String, sourceLine: Int) {
        self.id = id
        self.level = level
        self.plainText = plainText
        self.sourceLine = sourceLine
    }
}

/// 块级节点（渲染分块的最小单位）
public indirect enum BlockNode: Equatable, Sendable {
    case heading(level: Int, inlines: [InlineNode], sourceLine: Int)
    case paragraph(inlines: [InlineNode], sourceLine: Int)
    case codeBlock(language: String?, code: String, sourceLine: Int)
    case list(ordered: Bool, start: Int, items: [ListItem], sourceLine: Int)
    case table(header: [[InlineNode]], rows: [[[InlineNode]]], sourceLine: Int)
    case blockQuote(blocks: [BlockNode], sourceLine: Int)
    case thematicBreak(sourceLine: Int)
    case htmlBlock(html: String, sourceLine: Int)
    /// FR-02：不支持的语法原样显示源文本，降级不报错
    case fallback(source: String, sourceLine: Int)

    public var sourceLine: Int {
        switch self {
        case .heading(_, _, let line): return line
        case .paragraph(_, let line): return line
        case .codeBlock(_, _, let line): return line
        case .list(_, _, _, let line): return line
        case .table(_, _, let line): return line
        case .blockQuote(_, let line): return line
        case .thematicBreak(let line): return line
        case .htmlBlock(_, let line): return line
        case .fallback(_, let line): return line
        }
    }
}

/// 列表项：GFM 任务列表的勾选态
public struct ListItem: Equatable, Sendable {
    public let blocks: [BlockNode]
    /// nil = 普通列表项；true/false = 任务列表勾选态
    public let checkbox: Bool?

    public init(blocks: [BlockNode], checkbox: Bool? = nil) {
        self.blocks = blocks
        self.checkbox = checkbox
    }
}

/// 行内节点
public indirect enum InlineNode: Equatable, Sendable {
    case text(String)
    case emphasis([InlineNode])
    case strong([InlineNode])
    case strikethrough([InlineNode])
    case inlineCode(String)
    case link(destination: String, children: [InlineNode])
    case image(source: String, alt: String)
    case softBreak
    case hardBreak

    /// 提取纯文本（大纲标题、图片 alt 兜底、任务项摘要）
    public var plainText: String {
        switch self {
        case .text(let s), .inlineCode(let s): return s
        case .emphasis(let c), .strong(let c), .strikethrough(let c),
             .link(_, let c): return c.map(\.plainText).joined()
        case .image(_, let alt): return alt
        case .softBreak, .hardBreak: return " "
        }
    }
}

public extension Array where Element == InlineNode {
    var plainText: String { map(\.plainText).joined() }
}
