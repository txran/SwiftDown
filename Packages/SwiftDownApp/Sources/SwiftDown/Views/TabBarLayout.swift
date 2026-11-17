import SwiftUI

/// 标签栏的度量与纯布局判断。
///
/// 抽成纯函数是为了可断言：溢出判定和换行行数不依赖真实渲染，
/// 自检可以直接喂数字验证（渲染类断言只能截图肉眼看）。
enum TabBarMetrics {
    /// 单行高度（标签 32 + 上下留白）
    static let rowHeight: CGFloat = 34
    /// 多行模式最多显示 3 行，再多就在栏内上下滚动，避免把内容区挤没
    static let maxRows = 3
    static var maxWrapHeight: CGFloat { rowHeight * CGFloat(maxRows) }
    /// 单行模式左右箭头按钮宽度
    static let arrowWidth: CGFloat = 22
    /// 标签间距
    static let spacing: CGFloat = 2

    /// 内容是否放不下（放不下才显示滚动箭头）。
    ///
    /// 不用「预留箭头宽度」判定：箭头显示与否不改变内层内容宽度（内容在 ScrollView 里，宽度与可视宽度无关），
    /// 严格的 `内容 > 容器` 本身就不会抖，预留 44pt 反而让「刚好放得下」时白出两个箭头。
    static func needsArrows(contentWidth: CGFloat, containerWidth: CGFloat) -> Bool {
        guard containerWidth > 0 else { return false }
        return contentWidth > containerWidth + 0.5
    }

    /// 多行模式的换行行数（纯数学，用于自检与高度预估）
    static func wrappedRowCount(widths: [CGFloat], containerWidth: CGFloat) -> Int {
        guard containerWidth > 0, !widths.isEmpty else { return widths.isEmpty ? 0 : 1 }
        var rows = 1
        var x: CGFloat = 0
        for width in widths {
            if x > 0, x + width > containerWidth {
                rows += 1
                x = width + spacing
            } else {
                x += width + spacing
            }
        }
        return rows
    }
}

/// 多行换行布局（不用 LazyVGrid：标签宽度随文件名变化，需要 flow 行为）
struct TabFlowLayout: Layout {
    var spacing: CGFloat = TabBarMetrics.spacing

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth.isFinite ? maxWidth : max(0, x - spacing),
                      height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y),
                          anchor: .topLeading,
                          proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
