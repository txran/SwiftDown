import Foundation

/// 一次文本编辑的差量记录（撤销/重做与增量渲染的最小单位）
public struct TextEdit: Equatable, Sendable {
    /// 编辑发生的 UTF-16 区间（编辑前坐标）
    public let range: Range<Int>
    /// 被替换掉的原文本
    public let replaced: String
    /// 新写入的文本
    public let inserted: String

    public init(range: Range<Int>, replaced: String, inserted: String) {
        self.range = range
        self.replaced = replaced
        self.inserted = inserted
    }

    /// 撤销此编辑需要应用的反向操作区间
    public var inverseRange: Range<Int> {
        range.lowerBound..<(range.lowerBound + inserted.utf16.count)
    }
}

/// 差量撤销栈（FR-04：无上限直至本次会话）。
///
/// 内存策略（设计文档 §4.2 已知限制）：软上限 2000 步，超出时合并最旧的两条相邻差量。
/// 相邻指后一条的区间起点等于前一条的终点——可安全拼接；
/// 不相邻（中间有未记录变更）时保守丢弃最旧一条，避免构造错误的合并结果。
public struct UndoStack: Sendable {

    public var limit: Int
    private var undoEdits: [TextEdit] = []
    private var redoEdits: [TextEdit] = []

    public init(limit: Int = 2000) {
        self.limit = limit
    }

    public var canUndo: Bool { !undoEdits.isEmpty }
    public var canRedo: Bool { !redoEdits.isEmpty }
    public var undoCount: Int { undoEdits.count }

    /// 记录一次新编辑（清空重做栈，符合编辑器惯例）
    public mutating func record(_ edit: TextEdit) {
        guard edit.replaced != edit.inserted else { return }
        undoEdits.append(edit)
        redoEdits.removeAll()
        compactIfNeeded()
    }

    /// 返回需要应用的「反向编辑」（调用方负责真正改文本）
    public mutating func undo() -> TextEdit? {
        guard let last = undoEdits.popLast() else { return nil }
        redoEdits.append(last)
        return TextEdit(range: last.inverseRange,
                        replaced: last.inserted,
                        inserted: last.replaced)
    }

    /// 返回需要重放的正向编辑
    public mutating func redo() -> TextEdit? {
        guard let last = redoEdits.popLast() else { return nil }
        undoEdits.append(last)
        return last
    }

    public mutating func clear() {
        undoEdits.removeAll()
        redoEdits.removeAll()
    }

    private mutating func compactIfNeeded() {
        guard undoEdits.count > limit, undoEdits.count >= 2 else { return }
        let a = undoEdits[0]
        let b = undoEdits[1]
        // 相邻判定：插入操作的 range 是空区间，终点必须用 lower + inserted 长度而非 range.upper
        let aEnd = a.range.lowerBound + a.inserted.utf16.count
        if b.range.lowerBound == aEnd {
            let merged = TextEdit(
                range: a.range.lowerBound..<(aEnd + b.inserted.utf16.count),
                replaced: a.replaced + b.replaced,
                inserted: a.inserted + b.inserted
            )
            undoEdits.removeFirst(2)
            undoEdits.insert(merged, at: 0)
        } else {
            undoEdits.removeFirst()
        }
    }
}
