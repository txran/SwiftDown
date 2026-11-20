import AppKit
import SwiftUI

/// 预览里代码块的横向滚动容器。
///
/// **为什么不用 SwiftUI 的 `ScrollView(.horizontal)`**：
/// 它在外层竖向 `ScrollView` 里嵌套时，内层 `NSScrollView` 会把纵向滚轮事件一并吃掉
/// ——它自己只能横向滚，纵向就当作「滚不动」，既不滚自己也不往外交。
/// 表现就是：鼠标停到代码块上，滚轮彻底失效（用户报的就是这个）。
///
/// 这里显式判定主导轴：竖向为主（含传统滚轮，`scrollingDeltaX` 恒为 0）就转交给外层的
/// 竖向滚动容器，横向为主才自己处理。
final class PreviewCodeScrollView: NSScrollView {

    override func scrollWheel(with event: NSEvent) {
        let dx = abs(event.scrollingDeltaX)
        let dy = abs(event.scrollingDeltaY)
        guard dy >= dx else {
            super.scrollWheel(with: event)
            return
        }
        // 事件交给外层。先用祖先里的滚动视图（确定性最高：直接调它的 scrollWheel），
        // 找不到再退到响应链——某些 SwiftUI 版本的 ScrollView 不在视图树里当祖先。
        if let outer = Self.enclosingScrollView(of: self) {
            outer.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }

    private static func enclosingScrollView(of view: NSView) -> NSScrollView? {
        var current = view.superview
        while let candidate = current {
            if let scrollView = candidate as? NSScrollView { return scrollView }
            current = candidate.superview
        }
        return nil
    }
}

/// 只读、不换行、可选中复制的代码文本视图（`NSViewRepresentable` 包装）。
///
/// 高度不用 `sizeThatFits` 反过来问 SwiftUI：那样要先 `updateNSView` 换文本、再让
/// SwiftUI 重新询尺寸，中间容易差一帧（先出 14pt 再跳）。既然不换行，行高只取决于
/// 行数，直接在 SwiftUI 侧算好 `.frame(height:)`，确定性更强。
struct CodeBlockText: NSViewRepresentable {

    let attributed: NSAttributedString
    let fontSize: CGFloat
    let inset: NSSize

    func makeNSView(context: Context) -> PreviewCodeScrollView {
        let scrollView = PreviewCodeScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = false
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.textContainerInset = inset
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                  height: CGFloat.greatestFiniteMagnitude)
        // 关键：容器宽度不跟随视图 → 代码不折行，超长行靠横向滚动看
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.heightTracksTextView = false
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                                       height: CGFloat.greatestFiniteMagnitude)
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: PreviewCodeScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        if textView.textStorage?.isEqual(to: attributed) != true {
            textView.textStorage?.setAttributedString(attributed)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
        }
        // 文档视图按内容撑开：宽度决定横向滚动量，高度对齐 SwiftUI 给的 frame
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        let size = NSSize(width: ceil(used.width) + inset.width * 2 + 2,
                          height: max(1, ceil(used.height) + inset.height * 2))
        if textView.frame.size != size {
            textView.frame = NSRect(origin: textView.frame.origin, size: size)
        }
    }

    /// 不换行时的确定高度：行数 × 行高 + 上下内边距
    static func height(for code: String, fontSize: CGFloat, inset: NSSize) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let lineHeight: CGFloat = ceil(font.ascender - font.descender + font.leading)
        let lineCount = code.components(separatedBy: "\n").count
        let lines: CGFloat = CGFloat(max(1, lineCount))
        let padding: CGFloat = inset.height * 2 + 2
        return lines * lineHeight + padding
    }
}
