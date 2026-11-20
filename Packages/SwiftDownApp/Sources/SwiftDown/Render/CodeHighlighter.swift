import Foundation
import SwiftDownPipeline
import SwiftUI

/// 代码块轻量高亮（FR-02：抽 10 种常用语言验证）。
///
/// 取舍说明：M1 用「词法扫描 + 语言关键字表」，不做语法分析。
/// 目的是可读性（关键字/字符串/注释/数字四类着色），不追求语义准确；
/// 真正需要精确高亮时在 M2 换 tree-sitter（设计文档 §6.4 已留口）。
enum CodeHighlighter {

    enum TokenKind { case keyword, string, comment, number, plain }

    private static let commentPrefixes: [String: [String]] = [
        "python": ["#"], "py": ["#"],
        "shell": ["#"], "bash": ["#"], "sh": ["#"], "zsh": ["#"],
        "ruby": ["#"], "yaml": ["#"], "yml": ["#"], "toml": ["#"],
        "swift": ["//"], "c": ["//"], "cpp": ["//"], "objective-c": ["//"],
        "java": ["//"], "javascript": ["//"], "js": ["//"], "typescript": ["//"], "ts": ["//"],
        "go": ["//"], "rust": ["//"], "rs": ["//"], "kotlin": ["//"], "kt": ["//"]
    ]

    private static let keywords: [String: Set<String>] = [
        "swift": ["func", "let", "var", "if", "else", "guard", "return", "struct", "class", "enum",
                  "protocol", "extension", "import", "public", "private", "internal", "final", "init",
                  "deinit", "self", "super", "true", "false", "nil", "for", "in", "while", "switch",
                  "case", "default", "try", "catch", "throw", "throws", "async", "await", "actor",
                  "some", "any", "where", "typealias", "static", "mutating", "convenience", "lazy"],
        "python": ["def", "class", "if", "elif", "else", "for", "while", "return", "import", "from",
                   "as", "with", "try", "except", "finally", "raise", "lambda", "None", "True", "False",
                   "and", "or", "not", "in", "is", "pass", "break", "continue", "global", "yield",
                   "async", "await", "self"],
        "javascript": ["function", "const", "let", "var", "if", "else", "for", "while", "return",
                       "class", "extends", "new", "this", "import", "export", "default", "from",
                       "async", "await", "try", "catch", "finally", "throw", "typeof", "instanceof",
                       "true", "false", "null", "undefined", "switch", "case", "break", "continue"],
        "typescript": ["function", "const", "let", "var", "if", "else", "for", "while", "return",
                       "class", "interface", "type", "enum", "extends", "implements", "new", "this",
                       "import", "export", "default", "from", "async", "await", "try", "catch",
                       "throw", "true", "false", "null", "undefined", "public", "private", "readonly"],
        "java": ["public", "private", "protected", "class", "interface", "extends", "implements",
                 "void", "static", "final", "new", "if", "else", "for", "while", "return", "try",
                 "catch", "finally", "throw", "throws", "import", "package", "this", "super",
                 "true", "false", "null", "int", "long", "double", "float", "boolean", "String"],
        "go": ["func", "package", "import", "var", "const", "type", "struct", "interface", "if",
               "else", "for", "range", "return", "go", "defer", "chan", "select", "case", "switch",
               "default", "map", "make", "new", "nil", "true", "false", "error", "string", "int"],
        "rust": ["fn", "let", "mut", "const", "struct", "enum", "impl", "trait", "pub", "use", "mod",
                 "if", "else", "match", "for", "while", "loop", "return", "self", "Self", "super",
                 "Some", "None", "Ok", "Err", "true", "false", "async", "await", "move", "where"],
        "c": ["int", "char", "float", "double", "void", "struct", "union", "enum", "typedef",
              "static", "const", "if", "else", "for", "while", "switch", "case", "return", "break",
              "continue", "sizeof", "include", "define", "NULL"],
        "shell": ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case", "esac",
                  "function", "return", "export", "local", "echo", "cd", "set", "unset", "source"],
        "json": ["true", "false", "null"]
    ]

    static func highlighted(_ code: String, language: String?, size: CGFloat) -> AttributedString {
        var result = AttributedString()
        for (text, kind) in pieces(code, language: language) {
            append(&result, text, kind: kind, size: size)
        }
        return result.characters.isEmpty ? AttributedString(code) : result
    }

    /// AppKit 版：预览的代码块挂在只读 `NSTextView` 上（为了横向不换行 + 滚轮穿透，
    /// 见 `PreviewCodeView`），所以要多一条 `NSAttributedString` 出口。
    /// 词法分类与 SwiftUI 版共用 `pieces`，两边不会漂移。
    static func highlightedNS(_ code: String, language: String?, size: CGFloat) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        let result = NSMutableAttributedString()
        for (text, kind) in pieces(code, language: language) {
            var attrs: [NSAttributedString.Key: Any] = [.font: font]
            switch kind {
            case .keyword: attrs[.foregroundColor] = NSColor.systemPink
            case .string: attrs[.foregroundColor] = NSColor.systemRed
            case .comment: attrs[.foregroundColor] = NSColor.secondaryLabelColor
            case .number: attrs[.foregroundColor] = NSColor.systemOrange
            case .plain: break
            }
            result.append(NSAttributedString(string: text, attributes: attrs))
        }
        if result.length == 0 {
            return NSAttributedString(string: code, attributes: [.font: font])
        }
        return result
    }

    /// 词法切分：返回「片段 + 类别」，两种渲染目标各自拼装
    private static func pieces(_ code: String, language: String?) -> [(String, TokenKind)] {
        let lang = (language ?? "").lowercased().trimmingCharacters(in: .whitespaces)
        let keywordSet = keywords[normalize(lang)] ?? []
        let commentPrefix = commentPrefixes[normalize(lang)] ?? ["//"]

        var result: [(String, TokenKind)] = []
        let ns = code as NSString
        let full = NSRange(location: 0, length: ns.length)

        var lastEnd = 0
        for match in tokenRegex.matches(in: code, options: [], range: full) {
            if match.range.location > lastEnd {
                let gap = ns.substring(with: NSRange(location: lastEnd,
                                                    length: match.range.location - lastEnd))
                result.append((gap, .plain))
            }
            let token = ns.substring(with: match.range)
            result.append((token, classify(token, keywords: keywordSet, commentPrefix: commentPrefix)))
            lastEnd = NSMaxRange(match.range)
        }
        if lastEnd < ns.length {
            result.append((ns.substring(from: lastEnd), .plain))
        }
        return result
    }

    private static func normalize(_ lang: String) -> String {
        switch lang {
        case "py": return "python"
        case "js", "jsx": return "javascript"
        case "ts", "tsx": return "typescript"
        case "sh", "zsh", "bash", "console": return "shell"
        case "rs": return "rust"
        case "c++", "cpp", "cc", "h", "hpp", "objc", "objective-c": return "cpp"
        case "kt", "kotlin": return "java"
        case "yml": return "yaml"
        default: return lang
        }
    }

    private static func classify(_ token: String, keywords: Set<String>, commentPrefix: [String]) -> TokenKind {
        if token.hasPrefix("\"") || token.hasPrefix("'") || token.hasPrefix("`") { return .string }
        if token.hasPrefix("//") || token.hasPrefix("/*") || token.hasPrefix("--") { return .comment }
        if token.hasPrefix("#") { return commentPrefix.contains("#") ? .comment : .plain }
        if let first = token.first, first.isNumber { return .number }
        if keywords.contains(token) { return .keyword }
        return .plain
    }

    private static func append(_ result: inout AttributedString,
                               _ text: String,
                               kind: TokenKind,
                               size: CGFloat) {
        var piece = AttributedString(text)
        piece.font = .system(size: size, design: .monospaced)
        switch kind {
        case .keyword: piece.foregroundColor = .init(nsColor: .systemPink)
        case .string: piece.foregroundColor = .init(nsColor: .systemRed)
        case .comment: piece.foregroundColor = .init(nsColor: .secondaryLabelColor)
        case .number: piece.foregroundColor = .init(nsColor: .systemOrange)
        case .plain: break
        }
        result.append(piece)
    }

    private static let tokenRegex = try! NSRegularExpression(
        pattern: #"(?s)/\*.*?\*/|//[^\n]*|--[^\n]*|#[^\n]*|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*'|`(?:\\.|[^`\\\n])*`|\b\d+(?:\.\d+)?\b|\b[A-Za-z_][A-Za-z0-9_]*\b"#
    )
}
