import Foundation

/// 编辑器模型门面（设计文档 §4.2）：文本缓冲 + 撤销栈的唯一写入口。
/// TextKit 2 视图层只通过此类提交变更，保证「每次编辑都进入撤销栈且状态可追溯」。
public final class EditorBuffer {

    public private(set) var text: TextBuffer
    public private(set) var undoStack: UndoStack

    /// 文本变更通知（UI 桥接层用于刷新行号/语法高亮/触发预览）
    public var onChange: ((TextEdit) -> Void)?

    public init(text: String = "", undoLimit: Int = 2000) {
        self.text = TextBuffer(text)
        self.undoStack = UndoStack(limit: undoLimit)
    }

    public var string: String { text.string }
    public var canUndo: Bool { undoStack.canUndo }
    public var canRedo: Bool { undoStack.canRedo }

    /// 与 NSTextStorage.replaceCharacters(in:with:) 对齐的编辑入口
    @discardableResult
    public func replace(range: Range<Int>, with newText: String) -> TextEdit {
        let ns = text.string as NSString
        let n = ns.length
        let lower = max(0, min(range.lowerBound, n))
        let upper = max(lower, min(range.upperBound, n))
        let clamped = lower..<upper
        let replaced = ns.substring(with: NSRange(location: clamped.lowerBound, length: clamped.count))
        let edit = TextEdit(range: clamped, replaced: replaced, inserted: newText)
        text.replace(range: clamped, with: newText)
        undoStack.record(edit)
        onChange?(edit)
        return edit
    }

    /// 应用语法辅助结果
    @discardableResult
    public func apply(_ result: MarkdownSyntaxHelper.EditResult) -> TextEdit {
        replace(range: result.range, with: result.replacement)
    }

    @discardableResult
    public func undo() -> TextEdit? {
        guard let inverse = undoStack.undo() else { return nil }
        text.replace(range: inverse.range, with: inverse.inserted)
        onChange?(inverse)
        return inverse
    }

    @discardableResult
    public func redo() -> TextEdit? {
        guard let forward = undoStack.redo() else { return nil }
        text.replace(range: forward.inverseRange, with: forward.inserted)
        onChange?(forward)
        return forward
    }

    /// 外部重载（静默重载/冲突采用磁盘版）：清空撤销栈，避免跨文档态混用
    public func reload(with newText: String) {
        text = TextBuffer(newText)
        undoStack.clear()
    }
}
