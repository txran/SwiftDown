import Foundation

/// 解析协议：上层（Render / 大纲 / 同步滚动）只依赖此抽象。
/// 实现可替换（swift-markdown / Ink / 自研），切换零上层改动。
public protocol MarkdownParsing: Sendable {
    /// 单次解析同时产出渲染块树与标题树（设计文档 §4.3）
    func parse(_ source: String) throws -> MarkdownAST
}

public enum ParseError: Error, Equatable {
    /// EX-08：解析引擎异常，上层捕获后降级纯文本
    case engineFailure(reason: String)
}
