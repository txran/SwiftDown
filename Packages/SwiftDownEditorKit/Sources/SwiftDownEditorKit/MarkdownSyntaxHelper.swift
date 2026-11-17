import Foundation

/// Markdown 语法辅助（FR-04）：纯文本变换，无 UI 依赖，可完整单测。
/// 所有偏移为 UTF-16；返回新的文本替换结果与建议选区。
public enum MarkdownSyntaxHelper {

    public struct EditResult: Equatable, Sendable {
        public let range: Range<Int>
        public let replacement: String
        /// 编辑后建议的选区（UTF-16）
        public let newSelection: Range<Int>

        public init(range: Range<Int>, replacement: String, newSelection: Range<Int>) {
            self.range = range
            self.replacement = replacement
            self.newSelection = newSelection
        }
    }

    /// Cmd+B / Cmd+I：包裹或取消包裹选区
    /// - 选区非空：包裹为 `**text**`；若选区本身已被包裹则移除标记
    /// - 选区为空：插入成对标记并把光标放中间
    public static func toggleWrap(text: String, selection: Range<Int>, marker: String) -> EditResult {
        let ns = text as NSString
        let sel = clamp(selection, in: text)
        let markerLen = marker.utf16.count

        guard sel.count > 0 else {
            let replacement = marker + marker
            let caret = sel.lowerBound + markerLen
            return EditResult(range: sel.lowerBound..<sel.lowerBound,
                              replacement: replacement,
                              newSelection: caret..<caret)
        }

        let selected = ns.substring(with: NSRange(location: sel.lowerBound, length: sel.count))

        // 已包裹：移除内层标记
        if selected.hasPrefix(marker), selected.hasSuffix(marker), sel.count >= markerLen * 2 {
            let start = sel.lowerBound + markerLen
            let end = sel.upperBound - markerLen
            let inner = ns.substring(with: NSRange(location: start, length: end - start))
            return EditResult(range: sel,
                              replacement: inner,
                              newSelection: sel.lowerBound..<(sel.lowerBound + inner.utf16.count))
        }

        // 选区外紧邻标记（如把光标放在 **|text|** 内部选中 text）→ 也做移除
        let outerLower = sel.lowerBound - markerLen
        let outerUpper = sel.upperBound + markerLen
        if outerLower >= 0, outerUpper <= ns.length,
           ns.substring(with: NSRange(location: outerLower, length: markerLen)) == marker,
           ns.substring(with: NSRange(location: sel.upperBound, length: markerLen)) == marker {
            return EditResult(range: outerLower..<outerUpper,
                              replacement: selected,
                              newSelection: outerLower..<(outerLower + sel.count))
        }

        let replacement = marker + selected + marker
        return EditResult(range: sel,
                          replacement: replacement,
                          newSelection: sel.lowerBound..<(sel.lowerBound + replacement.utf16.count))
    }

    public static func toggleBold(text: String, selection: Range<Int>) -> EditResult {
        toggleWrap(text: text, selection: selection, marker: "**")
    }

    public static func toggleItalic(text: String, selection: Range<Int>) -> EditResult {
        toggleWrap(text: text, selection: selection, marker: "*")
    }

    /// 回车续行（FR-04 验收：光标在列表项内回车自动生成同级前缀）
    /// 返回应在当前位置插入的前缀；nil 表示不续行（当前行是空列表项 → 结束列表）
    public static func listContinuation(forLine line: String) -> String? {
        // 引用 + 列表组合：> - item
        if let (quotePrefix, rest) = splitQuotePrefix(line) {
            if let inner = listContinuation(forLine: rest) {
                return quotePrefix + inner
            }
            // 引用行本身：继续引用
            return rest.trimmingCharacters(in: .whitespaces).isEmpty ? nil : quotePrefix
        }

        let trimmedLeading = line.drop(while: { $0 == " " || $0 == "\t" })
        let indent = String(line.prefix(line.count - trimmedLeading.count))
        let body = String(trimmedLeading)

        // 任务列表：- [ ] / - [x]
        if let match = matchTaskItem(body) {
            let content = String(body.dropFirst(match.prefix.count))
            if content.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
            return indent + match.prefix
        }

        // 无序列表：- * +
        if let match = matchBulletItem(body) {
            let content = String(body.dropFirst(match.prefix.count))
            if content.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
            return indent + match.prefix
        }

        // 有序列表：1. / 2)
        if let match = matchOrderedItem(body) {
            let content = String(body.dropFirst(match.prefix.count))
            if content.trimmingCharacters(in: .whitespaces).isEmpty { return nil }
            return indent + "\(match.number + 1)\(match.delimiter) "
        }

        return nil
    }

    /// 对整段文本应用编辑（便于测试与 TextKit 桥接层复用）
    public static func apply(_ text: String, _ result: EditResult) -> String {
        let ns = NSMutableString(string: text)
        ns.replaceCharacters(in: NSRange(location: result.range.lowerBound, length: result.range.count),
                             with: result.replacement)
        return ns as String
    }

    // MARK: - 匹配

    private struct TaskMatch { let prefix: String }
    private struct BulletMatch { let prefix: String }
    private struct OrderedMatch { let number: Int; let delimiter: String; let prefix: String }

    private static func matchTaskItem(_ s: String) -> TaskMatch? {
        // - [ ] / * [x] / + [X]
        guard s.count >= 6 else { return nil }
        let chars = Array(s)
        guard "-*+".contains(chars[0]), chars[1] == " " else { return nil }
        guard chars[2] == "[" else { return nil }
        guard chars[3] == " " || chars[3] == "x" || chars[3] == "X" else { return nil }
        guard chars[4] == "]" else { return nil }
        guard chars[5] == " " else { return nil }
        // 续行产生的新任务项默认未勾选（- [x] → - [ ]）
        return TaskMatch(prefix: String(chars[0]) + " [ ] ")
    }

    private static func matchBulletItem(_ s: String) -> BulletMatch? {
        guard s.count >= 2 else { return nil }
        let chars = Array(s)
        guard "-*+".contains(chars[0]), chars[1] == " " else { return nil }
        // 任务列表已在前面处理，这里排除
        guard !(chars.count >= 3 && chars[2] == "[") else { return nil }
        return BulletMatch(prefix: String(chars[0..<2]))
    }

    private static func matchOrderedItem(_ s: String) -> OrderedMatch? {
        var i = 0
        let chars = Array(s)
        while i < chars.count, chars[i].isNumber { i += 1 }
        guard i > 0, i < chars.count else { return nil }
        guard chars[i] == "." || chars[i] == ")" else { return nil }
        guard i + 1 < chars.count, chars[i + 1] == " " else { return nil }
        let number = Int(String(chars[0..<i])) ?? 1
        return OrderedMatch(number: number,
                            delimiter: String(chars[i]),
                            prefix: String(chars[0...i]) + " ")
    }

    private static func splitQuotePrefix(_ line: String) -> (prefix: String, rest: String)? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        let indentCount = line.count - trimmed.count
        guard trimmed.first == ">" else { return nil }
        let afterMarker = trimmed.dropFirst()
        let space = afterMarker.first == " " ? " " : ""
        let prefix = String(line.prefix(indentCount)) + ">" + space
        let rest = String(afterMarker.dropFirst(space.count))
        return (prefix, rest)
    }

    private static func clamp(_ range: Range<Int>, in text: String) -> Range<Int> {
        let n = text.utf16.count
        let lower = max(0, min(range.lowerBound, n))
        let upper = max(lower, min(range.upperBound, n))
        return lower..<upper
    }
}
