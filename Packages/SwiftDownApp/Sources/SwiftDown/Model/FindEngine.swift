import Foundation

/// 查找选项（Aa / 整词 / 正则）
struct SearchOptions: Equatable, Sendable {
    var caseSensitive = false
    var wholeWord = false
    var regex = false
}

/// 查找范围：当前文档全文 / 所有打开的标签
enum SearchScope: String, CaseIterable, Identifiable, Sendable {
    case document, allTabs

    var id: String { rawValue }

    var label: String {
        switch self {
        case .document: return "当前文档"
        case .allTabs: return "所有标签"
        }
    }
}

/// 一处命中。`range` 是 **UTF-16** 偏移，与 NSString / NSTextView 同口径。
struct SearchMatch: Identifiable, Equatable, Sendable {
    let range: NSRange
    /// 1-based 行号
    let line: Int
    /// 该行去首尾空白的片段，用于「所有标签」结果列表
    let preview: String

    var id: String { "\(range.location):\(range.length)" }
}

/// 单个标签的命中集合（「所有标签」范围下的分组单位）
struct TabSearchResult: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let path: String
    let matches: [SearchMatch]
}

/// 查找内核：只做「字符串 → 命中区间」的纯粹计算，不碰 UI、不碰文件。
///
/// 为什么单独抽出来：这套逻辑要被三处用（查找栏、替换、自检），
/// 而且它的边界条件最密（空查询、零长匹配、大小写、整词、正则语法错误）。
/// 放在视图里就只能靠手点验证，抽成纯函数后自检可以逐条断言。
enum FindEngine {

    /// 单标签命中上限。
    /// 上限存在的意义不是性能（扫描是 O(n)），而是内存与 UI：十万处命中会把
    /// 结果列表和高亮区间表撑爆，而用户实际只会看前几十处。
    static let maxMatchesPerTab = 500

    private static let previewLimit = 160

    /// 正则语法校验。返回 `nil` 表示可用，否则是给用户看的原因。
    static func validate(query: String, options: SearchOptions) -> String? {
        guard options.regex, !query.isEmpty else { return nil }
        do {
            _ = try NSRegularExpression(pattern: query, options: regexOptions(options))
            return nil
        } catch {
            return "正则表达式无效"
        }
    }

    /// 计算全部命中（按位置升序）。
    ///
    /// - Parameters:
    ///   - limit: 超过后停止，避免病态输入（如单字符查询）产生巨量结果
    static func matches(in text: String,
                        query: String,
                        options: SearchOptions,
                        limit: Int = maxMatchesPerTab) -> [SearchMatch] {
        guard !query.isEmpty, !text.isEmpty, limit > 0 else { return [] }
        let ns = text as NSString
        let length = ns.length
        var ranges: [NSRange] = []
        ranges.reserveCapacity(min(limit, 64))

        if options.regex {
            guard let regex = try? NSRegularExpression(pattern: query, options: regexOptions(options)) else {
                return []
            }
            let full = NSRange(location: 0, length: length)
            regex.enumerateMatches(in: text, options: [], range: full) { result, _, stop in
                guard let result else { return }
                // 零长匹配（如 `^`、`\b`）没有可替换的实体，且会让替换陷入不动点，直接忽略
                guard result.range.length > 0 else { return }
                if options.wholeWord, !isWholeWord(ns, result.range) { return }
                ranges.append(result.range)
                if ranges.count >= limit { stop.pointee = true }
            }
        } else {
            let compareOptions: NSString.CompareOptions = options.caseSensitive ? [] : [.caseInsensitive]
            var cursor = 0
            while cursor < length {
                let searchRange = NSRange(location: cursor, length: length - cursor)
                let found = ns.range(of: query, options: compareOptions, range: searchRange)
                if found.location == NSNotFound { break }
                if !options.wholeWord || isWholeWord(ns, found) {
                    ranges.append(found)
                    if ranges.count >= limit { break }
                }
                // +max(1,...) 防零长 query（理论上进不来）导致死循环
                cursor = found.location + max(1, found.length)
            }
        }

        guard !ranges.isEmpty else { return [] }
        let starts = lineStarts(of: ns)
        return ranges.map { range in
            SearchMatch(range: range,
                        line: lineNumber(at: range.location, lineStarts: starts),
                        preview: previewLine(ns, at: range.location))
        }
    }

    // MARK: - 内部

    private static func regexOptions(_ options: SearchOptions) -> NSRegularExpression.Options {
        // anchorsMatchLines：让 ^ / $ 匹配每一行的行首行尾，而不是整个文本的开头结尾。
        // 在编辑器里搜「以 # 开头的行」是常见需求，按整文本语义写 `^#` 会一处都搜不到。
        var result: NSRegularExpression.Options = [.anchorsMatchLines]
        if !options.caseSensitive { result.insert(.caseInsensitive) }
        return result
    }

    /// 整词判定：命中两侧都不是「词内字符」。
    ///
    /// 词内字符 = 字母数字 + 下划线 + CJK。把 CJK 也算进来是刻意的：
    /// 中文没有空格分词，若不这么算，「单词」在中文里几乎永远命中（因为两侧是汉字，
    /// 汉字不是 alphanumeric，会被当成词边界），整词开关对中文就失效了。
    private static func isWholeWord(_ ns: NSString, _ range: NSRange) -> Bool {
        let before: unichar = range.location > 0 ? ns.character(at: range.location - 1) : 0
        let afterIndex = range.location + range.length
        let after: unichar = afterIndex < ns.length ? ns.character(at: afterIndex) : 0
        return !isWordUnit(before) && !isWordUnit(after)
    }

    private static func isWordUnit(_ unit: unichar) -> Bool {
        guard unit != 0, let scalar = UnicodeScalar(unit) else { return false }
        if (0x4E00...0x9FFF).contains(scalar.value) { return true }
        return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
    }

    /// 逻辑行起始偏移表（末尾换行不额外算一行，与编辑器行号同口径）
    static func lineStarts(of ns: NSString) -> [Int] {
        var starts: [Int] = [0]
        let length = ns.length
        var cursor = 0
        while cursor < length {
            var lineStart = 0
            var lineEnd = 0
            var contentsEnd = 0
            ns.getLineStart(&lineStart, end: &lineEnd, contentsEnd: &contentsEnd,
                            for: NSRange(location: cursor, length: 0))
            if lineEnd <= cursor { break }
            if lineEnd < length { starts.append(lineEnd) }
            cursor = lineEnd
        }
        return starts
    }

    static func lineNumber(at offset: Int, lineStarts: [Int]) -> Int {
        guard !lineStarts.isEmpty else { return 1 }
        var low = 0
        var high = lineStarts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if lineStarts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    private static func previewLine(_ ns: NSString, at location: Int) -> String {
        guard ns.length > 0 else { return "" }
        let safe = min(max(0, location), ns.length - 1)
        let lineRange = ns.lineRange(for: NSRange(location: safe, length: 0))
        var text = ns.substring(with: lineRange).trimmingCharacters(in: .whitespacesAndNewlines)
        text = text.replacingOccurrences(of: "\t", with: " ")
        if text.count > previewLimit {
            text = String(text.prefix(previewLimit)) + "…"
        }
        return text
    }
}
