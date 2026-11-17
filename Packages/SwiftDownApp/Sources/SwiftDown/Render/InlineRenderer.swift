import Foundation
import SwiftDownPipeline
import SwiftUI

/// 行内节点 → AttributedString（FR-02 行内语法）
enum InlineRenderer {

    /// 段落内可能出现图片，图片无法塞进 AttributedString，
    /// 因此按「文本段 / 图片」切分，由渲染层分别处理。
    enum Segment {
        case text(AttributedString)
        case image(source: String, alt: String)
    }

    static func attributed(_ nodes: [InlineNode], size: CGFloat) -> AttributedString {
        var result = AttributedString()
        append(nodes, into: &result, size: size, strong: false, emphasized: false,
               strike: false, link: nil)
        return result
    }

    static func segments(_ nodes: [InlineNode], size: CGFloat) -> [Segment] {
        var segments: [Segment] = []
        var pendingText: [InlineNode] = []

        func flushText() {
            guard !pendingText.isEmpty else { return }
            segments.append(.text(attributed(pendingText, size: size)))
            pendingText.removeAll()
        }

        for node in nodes {
            if case .image(let source, let alt) = node {
                flushText()
                segments.append(.image(source: source, alt: alt))
            } else {
                pendingText.append(node)
            }
        }
        flushText()
        return segments
    }

    private static func append(_ nodes: [InlineNode],
                               into result: inout AttributedString,
                               size: CGFloat,
                               strong: Bool,
                               emphasized: Bool,
                               strike: Bool,
                               link: URL?) {
        for node in nodes {
            switch node {
            case .text(let text):
                result.append(styled(text, size: size, strong: strong, emphasized: emphasized,
                                     strike: strike, link: link, code: false))

            case .inlineCode(let code):
                result.append(styled(code, size: size, strong: strong, emphasized: emphasized,
                                     strike: strike, link: link, code: true))

            case .strong(let children):
                append(children, into: &result, size: size, strong: true,
                       emphasized: emphasized, strike: strike, link: link)

            case .emphasis(let children):
                append(children, into: &result, size: size, strong: strong,
                       emphasized: true, strike: strike, link: link)

            case .strikethrough(let children):
                append(children, into: &result, size: size, strong: strong,
                       emphasized: emphasized, strike: true, link: link)

            case .link(let destination, let children):
                var url: URL?
                if let parsed = URL(string: destination), parsed.scheme != nil {
                    url = parsed
                } else if let parsed = URL(string: destination.addingPercentEncoding(
                    withAllowedCharacters: .urlPathAllowed) ?? destination) {
                    url = parsed
                }
                append(children, into: &result, size: size, strong: strong,
                       emphasized: emphasized, strike: strike, link: url)

            case .image(_, let alt):
                // 图片在 segments 层已单独处理；此处只保留 alt 文本兜底
                result.append(styled(alt, size: size, strong: strong, emphasized: emphasized,
                                     strike: strike, link: link, code: false))

            case .softBreak:
                result.append(AttributedString(" "))

            case .hardBreak:
                result.append(AttributedString("\n"))
            }
        }
    }

    private static func styled(_ text: String,
                               size: CGFloat,
                               strong: Bool,
                               emphasized: Bool,
                               strike: Bool,
                               link: URL?,
                               code: Bool) -> AttributedString {
        var piece = AttributedString(text)
        if code {
            piece.font = .system(size: size - 0.5, design: .monospaced)
            piece.backgroundColor = Color(nsColor: .quaternaryLabelColor)
        } else {
            var font: Font = .system(size: size)
            if strong && emphasized {
                font = .system(size: size, weight: .bold).italic()
            } else if strong {
                font = .system(size: size, weight: .bold)
            } else if emphasized {
                font = .system(size: size).italic()
            }
            piece.font = font
        }
        if strike {
            piece.strikethroughStyle = .single
        }
        if let link {
            piece.link = link
            piece.foregroundColor = .init(nsColor: .linkColor)
            piece.underlineStyle = .single
        }
        return piece
    }
}
