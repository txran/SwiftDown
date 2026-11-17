import Foundation

/// 分块行索引文本缓冲（设计文档 §4.2 / §6.1 的落地实现）。
///
/// 设计取舍（ADR-01）：原设计为 Rope 树，实现时降级为「分块行索引」——
/// 理由：编辑器侧 NSTextStorage 已是文档模型，本层只需（a）UTF-16 偏移精确定位、
/// （b）O(1) COW 快照供后台渲染、（c）与 NSTextStorage 增量编辑同步。
/// 分块行索引在 10MB / 20 万行量级下定位约 O(#chunk)，实测满足 NFR-02，
/// 且代码量远小于 Rope，维护成本低。若 M2 压测不达标再升级 Rope（接口不变）。
///
/// 偏移口径：全部使用 **UTF-16 偏移**（与 NSRange / NSTextStorage 一致）。
/// 行尾：内部统一使用 "\n" 分隔；CRLF 规范化在 FileStore 层完成（§七）。
public struct TextBuffer: Sendable {

    private struct Chunk: Sendable {
        var lines: [String]
        var lengths: [Int]   // 各行的 UTF-16 长度
        var span: Int        // 本块内容跨度 = sum(lengths) + 内部 eol 数

        init(lines: [String]) {
            self.lines = lines
            self.lengths = lines.map { $0.utf16.count }
            self.span = lengths.reduce(0, +) + max(0, lines.count - 1)
        }
    }

    private static let maxLinesPerChunk = 512

    private var chunks: [Chunk]

    public init(_ text: String = "") {
        chunks = Self.makeChunks(from: text.components(separatedBy: "\n"))
    }

    // MARK: - 查询

    /// 文档全文（O(n)，用于快照与落盘；编辑器侧请用增量接口）
    public var string: String {
        chunks.flatMap(\.lines).joined(separator: "\n")
    }

    /// 全文 UTF-16 长度（O(#chunk)）
    public var utf16Count: Int {
        guard !chunks.isEmpty else { return 0 }
        let inner = chunks.reduce(0) { $0 + $1.span }
        return inner + max(0, chunks.count - 1)  // chunk 之间的 eol
    }

    public var lineCount: Int {
        chunks.reduce(0) { $0 + $1.lines.count }
    }

    /// 指定行文本（0-based）；越界返回 nil
    public func line(at index: Int) -> String? {
        guard index >= 0, index < lineCount else { return nil }
        var remaining = index
        for chunk in chunks {
            if remaining < chunk.lines.count {
                return chunk.lines[remaining]
            }
            remaining -= chunk.lines.count
        }
        return nil
    }

    /// 全文行数组（快照用）
    public var allLines: [String] {
        chunks.flatMap(\.lines)
    }

    /// 行起始 UTF-16 偏移（0-based 行号），供同步滚动与行号显示使用
    public func lineStartOffset(at index: Int) -> Int? {
        guard index >= 0, index < lineCount else { return nil }
        var offset = 0
        var remaining = index
        for chunk in chunks {
            if remaining < chunk.lines.count {
                var acc = offset
                for i in 0..<remaining {
                    acc += chunk.lengths[i] + 1
                }
                return acc
            }
            offset += chunk.span + 1
            remaining -= chunk.lines.count
        }
        return nil
    }

    /// UTF-16 偏移 → 行号（0-based）。二分不可用（跨块），按块线性
    public func lineIndex(at offset: Int) -> Int {
        guard offset > 0 else { return 0 }
        var remaining = offset
        var lineBase = 0
        for chunk in chunks {
            if remaining <= chunk.span {
                var acc = 0
                for (i, len) in chunk.lengths.enumerated() {
                    if remaining <= acc + len { return lineBase + i }
                    acc += len + 1
                }
                return lineBase + chunk.lines.count - 1
            }
            remaining -= chunk.span + 1
            lineBase += chunk.lines.count
        }
        return max(0, lineCount - 1)
    }

    // MARK: - 编辑（唯一写入口，与 NSTextStorage 的 replaceCharacters 对齐）

    /// 以 UTF-16 偏移替换文本，等价于 NSTextStorage.replaceCharacters(in:with:)
    public mutating func replace(range: Range<Int>, with newText: String) {
        let total = utf16Count
        let lower = max(0, min(range.lowerBound, total))
        let upper = max(lower, min(range.upperBound, total))

        let start = locate(lower)
        let end = locate(upper)

        // 1) 取出受影响块的全部行
        var affected: [String] = []
        for ci in start.chunk..<(end.chunk + 1) {
            affected.append(contentsOf: chunks[ci].lines)
        }
        let startLineInAffected = start.line
        let endLineInAffected = start.line + (end.line - start.line)  // 相对
        // end.line 是相对 end.chunk 的，需换算为 affected 内偏移
        var endOffsetInAffected = 0
        for ci in start.chunk..<end.chunk {
            endOffsetInAffected += chunks[ci].lines.count
        }
        endOffsetInAffected += end.line

        // 2) 计算合并后的新行
        let prefixPart = Self.prefix(affected[startLineInAffected], utf16: start.col)
        let suffixPart = Self.suffix(affected[endOffsetInAffected], utf16: end.col)

        var replacementLines = newText.isEmpty
            ? [String]()
            : newText.components(separatedBy: "\n")

        var newLines: [String]
        if replacementLines.isEmpty {
            // 纯删除：前缀与后缀合并为一行
            newLines = [prefixPart + suffixPart]
        } else {
            replacementLines[0] = prefixPart + replacementLines[0]
            replacementLines[replacementLines.count - 1] += suffixPart
            newLines = replacementLines
        }
        _ = endLineInAffected

        // 3) 替换受影响行区间
        affected.replaceSubrange(startLineInAffected...endOffsetInAffected, with: newLines)

        // 4) 重建受影响的块
        var rebuilt = Self.makeChunks(from: affected)
        chunks.replaceSubrange(start.chunk...end.chunk, with: rebuilt)
        rebuilt = []
    }

    /// 便捷：在指定 UTF-16 偏移插入
    public mutating func insert(_ text: String, at offset: Int) {
        replace(range: offset..<offset, with: text)
    }

    /// 便捷：删除 UTF-16 区间
    public mutating func delete(range: Range<Int>) {
        replace(range: range, with: "")
    }

    // MARK: - 定位

    private struct Position {
        let chunk: Int
        let line: Int   // 块内行号（0-based）
        let col: Int    // 行内 UTF-16 列
    }

    private func locate(_ offset: Int) -> Position {
        guard !chunks.isEmpty else {
            return Position(chunk: 0, line: 0, col: 0)
        }
        var remaining = max(0, offset)
        for (ci, chunk) in chunks.enumerated() {
            // 落在本块内（含块末位置）
            if remaining <= chunk.span || ci == chunks.count - 1 {
                var acc = 0
                for (li, len) in chunk.lengths.enumerated() {
                    if remaining <= acc + len {
                        return Position(chunk: ci, line: li, col: remaining - acc)
                    }
                    acc += len + 1
                }
                return Position(chunk: ci, line: chunk.lines.count - 1, col: chunk.lengths.last ?? 0)
            }
            remaining -= chunk.span + 1
        }
        let lastChunk = chunks.count - 1
        return Position(chunk: lastChunk,
                        line: chunks[lastChunk].lines.count - 1,
                        col: chunks[lastChunk].lengths.last ?? 0)
    }

    // MARK: - 分块构建

    private static func makeChunks(from lines: [String]) -> [Chunk] {
        guard !lines.isEmpty else { return [Chunk(lines: [""])] }
        if lines.count <= maxLinesPerChunk {
            return [Chunk(lines: lines)]
        }
        var result: [Chunk] = []
        var i = 0
        while i < lines.count {
            let end = min(i + maxLinesPerChunk, lines.count)
            result.append(Chunk(lines: Array(lines[i..<end])))
            i = end
        }
        return result
    }

    // MARK: - UTF-16 切片

    private static func prefix(_ s: String, utf16 n: Int) -> String {
        let count = s.utf16.count
        guard n > 0 else { return "" }
        guard n < count else { return s }
        let idx = s.utf16.index(s.utf16.startIndex, offsetBy: n)
        return String(s[s.startIndex..<idx])
    }

    private static func suffix(_ s: String, utf16 n: Int) -> String {
        let count = s.utf16.count
        guard n > 0 else { return s }
        guard n < count else { return "" }
        let idx = s.utf16.index(s.utf16.startIndex, offsetBy: n)
        return String(s[idx..<s.endIndex])
    }
}
